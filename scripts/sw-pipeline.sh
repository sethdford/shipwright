#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline — Autonomous Feature Delivery (Idea → Production)        ║
# ║  Full GitHub integration · Auto-detection · Task tracking · Metrics    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="1.10.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

# ─── Intelligence Engine (optional) ──────────────────────────────────────────
# shellcheck source=sw-intelligence.sh
if [[ -f "$SCRIPT_DIR/sw-intelligence.sh" ]]; then
    source "$SCRIPT_DIR/sw-intelligence.sh"
fi
# shellcheck source=sw-pipeline-composer.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-composer.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-composer.sh"
fi
# shellcheck source=sw-developer-simulation.sh
if [[ -f "$SCRIPT_DIR/sw-developer-simulation.sh" ]]; then
    source "$SCRIPT_DIR/sw-developer-simulation.sh"
fi
# shellcheck source=sw-architecture-enforcer.sh
if [[ -f "$SCRIPT_DIR/sw-architecture-enforcer.sh" ]]; then
    source "$SCRIPT_DIR/sw-architecture-enforcer.sh"
fi
# shellcheck source=sw-adversarial.sh
if [[ -f "$SCRIPT_DIR/sw-adversarial.sh" ]]; then
    source "$SCRIPT_DIR/sw-adversarial.sh"
fi
# shellcheck source=sw-pipeline-vitals.sh
if [[ -f "$SCRIPT_DIR/sw-pipeline-vitals.sh" ]]; then
    source "$SCRIPT_DIR/sw-pipeline-vitals.sh"
fi

# ─── GitHub API Modules (optional) ─────────────────────────────────────────
# shellcheck source=sw-github-graphql.sh
[[ -f "$SCRIPT_DIR/sw-github-graphql.sh" ]] && source "$SCRIPT_DIR/sw-github-graphql.sh"
# shellcheck source=sw-github-checks.sh
[[ -f "$SCRIPT_DIR/sw-github-checks.sh" ]] && source "$SCRIPT_DIR/sw-github-checks.sh"
# shellcheck source=sw-github-deploy.sh
[[ -f "$SCRIPT_DIR/sw-github-deploy.sh" ]] && source "$SCRIPT_DIR/sw-github-deploy.sh"

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

# Parse coverage percentage from test output — multi-framework patterns
# Usage: parse_coverage_from_output <log_file>
# Outputs coverage percentage or empty string
parse_coverage_from_output() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return
    local cov=""
    # Jest/Istanbul: "Statements : 85.5%"
    cov=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # Istanbul table: "All files | 85.5"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+' "$log_file" 2>/dev/null | grep -oE '[0-9.]+$' || true)
    # pytest-cov: "TOTAL    500    75    85%"
    [[ -z "$cov" ]] && cov=$(grep -oE 'TOTAL\s+[0-9]+\s+[0-9]+\s+[0-9]+%' "$log_file" 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' | tail -1 || true)
    # Vitest: "All files  |  85.5  |"
    [[ -z "$cov" ]] && cov=$(grep -oE 'All files\s*\|\s*[0-9.]+\s*\|' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Go coverage: "coverage: 85.5% of statements"
    [[ -z "$cov" ]] && cov=$(grep -oE 'coverage:\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo tarpaulin: "85.50% coverage"
    [[ -z "$cov" ]] && cov=$(grep -oE '[0-9.]+%\s*coverage' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | head -1 || true)
    # Generic: "Coverage: 85.5%"
    [[ -z "$cov" ]] && cov=$(grep -oiE 'coverage:?\s*[0-9.]+%' "$log_file" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    echo "$cov"
}

format_duration() {
    local secs="$1"
    if [[ "$secs" -ge 3600 ]]; then
        printf "%dh %dm %ds" $((secs/3600)) $((secs%3600/60)) $((secs%60))
    elif [[ "$secs" -ge 60 ]]; then
        printf "%dm %ds" $((secs/60)) $((secs%60))
    else
        printf "%ds" "$secs"
    fi
}

_pipeline_compact_goal() {
    local goal="$1"
    local plan_file="${2:-}"
    local design_file="${3:-}"
    local compact="$goal"

    # Include plan summary (first 20 lines only)
    if [[ -n "$plan_file" && -f "$plan_file" ]]; then
        compact="${compact}

## Plan Summary
$(head -20 "$plan_file" 2>/dev/null || true)
[... full plan in .claude/pipeline-artifacts/plan.md]"
    fi

    # Include design key decisions only (grep for headers)
    if [[ -n "$design_file" && -f "$design_file" ]]; then
        compact="${compact}

## Key Design Decisions
$(grep -E '^#{1,3} ' "$design_file" 2>/dev/null | head -10 || true)
[... full design in .claude/pipeline-artifacts/design.md]"
    fi

    echo "$compact"
}

load_composed_pipeline() {
    local spec_file="$1"
    [[ ! -f "$spec_file" ]] && return 1

    # Read enabled stages from composed spec
    local composed_stages
    composed_stages=$(jq -r '.stages // [] | .[] | .id' "$spec_file" 2>/dev/null) || return 1
    [[ -z "$composed_stages" ]] && return 1

    # Override enabled stages
    COMPOSED_STAGES="$composed_stages"

    # Override per-stage settings
    local build_max
    build_max=$(jq -r '.stages[] | select(.id=="build") | .max_iterations // ""' "$spec_file" 2>/dev/null) || true
    [[ -n "$build_max" && "$build_max" != "null" ]] && COMPOSED_BUILD_ITERATIONS="$build_max"

    emit_event "pipeline.composed_loaded" "stages=$(echo "$composed_stages" | wc -l | tr -d ' ')"
    return 0
}

# ─── Structured Event Log ──────────────────────────────────────────────────
# Appends JSON events to ~/.shipwright/events.jsonl for metrics/traceability

EVENTS_DIR="${HOME}/.shipwright"
EVENTS_FILE="${EVENTS_DIR}/events.jsonl"

emit_event() {
    local event_type="$1"
    shift
    # Remaining args are key=value pairs
    local json_fields=""
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        # Numbers: don't quote; strings: quote
        if [[ "$val" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
            json_fields="${json_fields},\"${key}\":${val}"
        else
            # Escape quotes in value
            val="${val//\"/\\\"}"
            json_fields="${json_fields},\"${key}\":\"${val}\""
        fi
    done
    mkdir -p "$EVENTS_DIR"
    echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
}

# ─── Token / Cost Parsing ─────────────────────────────────────────────────
parse_claude_tokens() {
    local log_file="$1"
    local input_tok output_tok
    input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
    output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

    TOTAL_INPUT_TOKENS=$(( TOTAL_INPUT_TOKENS + ${input_tok:-0} ))
    TOTAL_OUTPUT_TOKENS=$(( TOTAL_OUTPUT_TOKENS + ${output_tok:-0} ))
}

# ─── Defaults ───────────────────────────────────────────────────────────────
GOAL=""
ISSUE_NUMBER=""
PIPELINE_NAME="standard"
PIPELINE_CONFIG=""
TEST_CMD=""
MODEL=""
AGENTS=""
SKIP_GATES=false
GIT_BRANCH=""
GITHUB_ISSUE=""
TASK_TYPE=""
REVIEWERS=""
LABELS=""
BASE_BRANCH="main"
NO_GITHUB=false
NO_GITHUB_LABEL=false
CI_MODE=false
DRY_RUN=false
IGNORE_BUDGET=false
COMPLETED_STAGES=""
MAX_ITERATIONS_OVERRIDE=""
MAX_RESTARTS_OVERRIDE=""
FAST_TEST_CMD_OVERRIDE=""
PR_NUMBER=""
AUTO_WORKTREE=false
WORKTREE_NAME=""
CLEANUP_WORKTREE=false
ORIGINAL_REPO_DIR=""
_cleanup_done=""

# GitHub metadata (populated during intake)
ISSUE_LABELS=""
ISSUE_MILESTONE=""
ISSUE_ASSIGNEES=""
ISSUE_BODY=""
PROGRESS_COMMENT_ID=""
REPO_OWNER=""
REPO_NAME=""
GH_AVAILABLE=false

# Timing
PIPELINE_START_EPOCH=""
STAGE_TIMINGS=""

PROJECT_ROOT=""
STATE_DIR=""
STATE_FILE=""
ARTIFACTS_DIR=""
TASKS_FILE=""

# ─── Help ───────────────────────────────────────────────────────────────────

show_help() {
    echo -e "${CYAN}${BOLD}shipwright pipeline${RESET} — Autonomous Feature Delivery"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright pipeline${RESET} <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}start${RESET}   --goal \"...\"    Start a new pipeline"
    echo -e "  ${CYAN}resume${RESET}                  Continue from last completed stage"
    echo -e "  ${CYAN}status${RESET}                  Show pipeline progress dashboard"
    echo -e "  ${CYAN}abort${RESET}                   Stop pipeline and mark aborted"
    echo -e "  ${CYAN}list${RESET}                    Show available pipeline templates"
    echo -e "  ${CYAN}show${RESET}    <name>          Display pipeline stages"
    echo ""
    echo -e "${BOLD}START OPTIONS${RESET}"
    echo -e "  ${DIM}--goal \"description\"${RESET}     What to build (required unless --issue)"
    echo -e "  ${DIM}--issue <number>${RESET}          Fetch goal from GitHub issue"
    echo -e "  ${DIM}--pipeline <name>${RESET}         Pipeline template (default: standard)"
    echo -e "  ${DIM}--test-cmd \"command\"${RESET}     Override test command (auto-detected if omitted)"
    echo -e "  ${DIM}--model <model>${RESET}           Override AI model (opus, sonnet, haiku)"
    echo -e "  ${DIM}--agents <n>${RESET}              Override agent count"
    echo -e "  ${DIM}--skip-gates${RESET}              Auto-approve all gates (fully autonomous)"
    echo -e "  ${DIM}--base <branch>${RESET}           Base branch for PR (default: main)"
    echo -e "  ${DIM}--reviewers \"a,b\"${RESET}        Request PR reviewers (auto-detected if omitted)"
    echo -e "  ${DIM}--labels \"a,b\"${RESET}            Add labels to PR (inherited from issue if omitted)"
    echo -e "  ${DIM}--no-github${RESET}               Disable GitHub integration"
    echo -e "  ${DIM}--no-github-label${RESET}         Don't modify issue labels"
    echo -e "  ${DIM}--ci${RESET}                      CI mode (skip gates, non-interactive)"
    echo -e "  ${DIM}--ignore-budget${RESET}           Skip budget enforcement checks"
    echo -e "  ${DIM}--worktree [=name]${RESET}         Run in isolated git worktree (parallel-safe)"
    echo -e "  ${DIM}--dry-run${RESET}                 Show what would happen without executing"
    echo -e "  ${DIM}--slack-webhook <url>${RESET}     Send notifications to Slack"
    echo -e "  ${DIM}--self-heal <n>${RESET}            Build→test retry cycles on failure (default: 2)"
    echo -e "  ${DIM}--max-iterations <n>${RESET}       Override max build loop iterations"
    echo -e "  ${DIM}--max-restarts <n>${RESET}         Max session restarts in build loop"
    echo -e "  ${DIM}--fast-test-cmd <cmd>${RESET}      Fast/subset test for build loop"
    echo -e "  ${DIM}--completed-stages \"a,b\"${RESET}   Skip these stages (CI resume)"
    echo ""
    echo -e "${BOLD}STAGES${RESET}  ${DIM}(configurable per pipeline template)${RESET}"
    echo -e "  intake → plan → design → build → test → review → pr → deploy → validate → monitor"
    echo ""
    echo -e "${BOLD}GITHUB INTEGRATION${RESET}  ${DIM}(automatic when gh CLI available)${RESET}"
    echo -e "  • Issue intake: fetch metadata, labels, milestone, self-assign"
    echo -e "  • Progress tracking: live updates posted as issue comments"
    echo -e "  • Task checklist: plan posted as checkbox list on issue"
    echo -e "  • PR creation: labels, milestone, reviewers auto-propagated"
    echo -e "  • Issue lifecycle: labeled in-progress → closed on completion"
    echo ""
    echo -e "${BOLD}SELF-HEALING${RESET}  ${DIM}(autonomous error recovery)${RESET}"
    echo -e "  • Build→test feedback loop: failures feed back as build context"
    echo -e "  • Configurable retry cycles (--self-heal N, default: 2)"
    echo -e "  • Auto-rebase before PR: handles base branch drift"
    echo -e "  • Signal-safe: Ctrl+C saves state for clean resume"
    echo -e "  • Git stash/restore: protects uncommitted work"
    echo ""
    echo -e "${BOLD}AUTO-DETECTION${RESET}  ${DIM}(zero-config for common setups)${RESET}"
    echo -e "  • Test command: package.json, Makefile, Cargo.toml, go.mod, etc."
    echo -e "  • Branch prefix: feat/, fix/, refactor/ based on task type"
    echo -e "  • Reviewers: from CODEOWNERS or recent git contributors"
    echo -e "  • Project type: language and framework detection"
    echo ""
    echo -e "${BOLD}NOTIFICATIONS${RESET}  ${DIM}(team awareness)${RESET}"
    echo -e "  • Slack: --slack-webhook <url>"
    echo -e "  • Custom webhook: set SHIPWRIGHT_WEBHOOK_URL env var"
    echo -e "  • Events: start, stage complete, failure, self-heal, done"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}# From GitHub issue (fully autonomous)${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 123 --skip-gates${RESET}"
    echo ""
    echo -e "  ${DIM}# From inline goal${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Add JWT authentication\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Hotfix with custom test command${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 456 --pipeline hotfix --test-cmd \"pytest\"${RESET}"
    echo ""
    echo -e "  ${DIM}# Full deployment pipeline with 3 agents${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --goal \"Build payment flow\" --pipeline full --agents 3${RESET}"
    echo ""
    echo -e "  ${DIM}# Parallel pipeline in isolated worktree${RESET}"
    echo -e "  ${DIM}shipwright pipeline start --issue 42 --worktree${RESET}"
    echo ""
    echo -e "  ${DIM}# Resume / monitor / abort${RESET}"
    echo -e "  ${DIM}shipwright pipeline resume${RESET}"
    echo -e "  ${DIM}shipwright pipeline status${RESET}"
    echo -e "  ${DIM}shipwright pipeline abort${RESET}"
    echo ""
}

# ─── Argument Parsing ───────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --goal)        GOAL="$2"; shift 2 ;;
            --issue)       ISSUE_NUMBER="$2"; shift 2 ;;
            --pipeline|--template) PIPELINE_NAME="$2"; shift 2 ;;
            --test-cmd)    TEST_CMD="$2"; shift 2 ;;
            --model)       MODEL="$2"; shift 2 ;;
            --agents)      AGENTS="$2"; shift 2 ;;
            --skip-gates)  SKIP_GATES=true; shift ;;
            --base)        BASE_BRANCH="$2"; shift 2 ;;
            --reviewers)   REVIEWERS="$2"; shift 2 ;;
            --labels)      LABELS="$2"; shift 2 ;;
            --no-github)   NO_GITHUB=true; shift ;;
            --no-github-label) NO_GITHUB_LABEL=true; shift ;;
            --ci)          CI_MODE=true; SKIP_GATES=true; shift ;;
            --ignore-budget) IGNORE_BUDGET=true; shift ;;
            --max-iterations) MAX_ITERATIONS_OVERRIDE="$2"; shift 2 ;;
            --completed-stages) COMPLETED_STAGES="$2"; shift 2 ;;
            --worktree=*) AUTO_WORKTREE=true; WORKTREE_NAME="${1#--worktree=}"; WORKTREE_NAME="${WORKTREE_NAME//[^a-zA-Z0-9_-]/}"; if [[ -z "$WORKTREE_NAME" ]]; then error "Invalid worktree name (alphanumeric, hyphens, underscores only)"; exit 1; fi; shift ;;
            --worktree)   AUTO_WORKTREE=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --slack-webhook) SLACK_WEBHOOK="$2"; shift 2 ;;
            --self-heal)   BUILD_TEST_RETRIES="${2:-3}"; shift 2 ;;
            --max-restarts) MAX_RESTARTS_OVERRIDE="$2"; shift 2 ;;
            --fast-test-cmd) FAST_TEST_CMD_OVERRIDE="$2"; shift 2 ;;
            --help|-h)     show_help; exit 0 ;;
            *)
                if [[ -z "$PIPELINE_NAME_ARG" ]]; then
                    PIPELINE_NAME_ARG="$1"
                fi
                shift ;;
        esac
    done
}

PIPELINE_NAME_ARG=""
parse_args "$@"

# ─── Directory Setup ────────────────────────────────────────────────────────

setup_dirs() {
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    STATE_DIR="$PROJECT_ROOT/.claude"
    STATE_FILE="$STATE_DIR/pipeline-state.md"
    ARTIFACTS_DIR="$STATE_DIR/pipeline-artifacts"
    TASKS_FILE="$STATE_DIR/pipeline-tasks.md"
    mkdir -p "$STATE_DIR" "$ARTIFACTS_DIR"
}

# ─── Pipeline Config Loading ───────────────────────────────────────────────

find_pipeline_config() {
    local name="$1"
    local locations=(
        "$REPO_DIR/templates/pipelines/${name}.json"
        "$HOME/.shipwright/pipelines/${name}.json"
    )
    for loc in "${locations[@]}"; do
        if [[ -f "$loc" ]]; then
            echo "$loc"
            return 0
        fi
    done
    return 1
}

load_pipeline_config() {
    # Check for intelligence-composed pipeline first
    local composed_pipeline="${ARTIFACTS_DIR}/composed-pipeline.json"
    if [[ -f "$composed_pipeline" ]] && type composer_validate_pipeline &>/dev/null; then
        # Use composed pipeline if fresh (< 1 hour old)
        local composed_age=99999
        local composed_mtime
        composed_mtime=$(stat -f %m "$composed_pipeline" 2>/dev/null || stat -c %Y "$composed_pipeline" 2>/dev/null || echo "0")
        if [[ "$composed_mtime" -gt 0 ]]; then
            composed_age=$(( $(now_epoch) - composed_mtime ))
        fi
        if [[ "$composed_age" -lt 3600 ]]; then
            local validate_json
            validate_json=$(cat "$composed_pipeline" 2>/dev/null || echo "")
            if [[ -n "$validate_json" ]] && composer_validate_pipeline "$validate_json" 2>/dev/null; then
                PIPELINE_CONFIG="$composed_pipeline"
                info "Pipeline: ${BOLD}composed${RESET} ${DIM}(intelligence-driven)${RESET}"
                emit_event "pipeline.composed_loaded" "issue=${ISSUE_NUMBER:-0}"
                return
            fi
        fi
    fi

    PIPELINE_CONFIG=$(find_pipeline_config "$PIPELINE_NAME") || {
        error "Pipeline template not found: $PIPELINE_NAME"
        echo -e "  Available templates: ${DIM}shipwright pipeline list${RESET}"
        exit 1
    }
    info "Pipeline: ${BOLD}$PIPELINE_NAME${RESET} ${DIM}($PIPELINE_CONFIG)${RESET}"
}

CURRENT_STAGE_ID=""

# Notification / webhook
SLACK_WEBHOOK=""
NOTIFICATION_ENABLED=false

# Self-healing
BUILD_TEST_RETRIES=2
STASHED_CHANGES=false
SELF_HEAL_COUNT=0

# ─── Cost Tracking ───────────────────────────────────────────────────────
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0
COST_MODEL_RATES='{"opus":{"input":15,"output":75},"sonnet":{"input":3,"output":15},"haiku":{"input":0.25,"output":1.25}}'

# ─── Heartbeat ────────────────────────────────────────────────────────────────
HEARTBEAT_PID=""

start_heartbeat() {
    local job_id="${PIPELINE_NAME:-pipeline-$$}"
    (
        while true; do
            "$SCRIPT_DIR/sw-heartbeat.sh" write "$job_id" \
                --pid $$ \
                --issue "${ISSUE_NUMBER:-0}" \
                --stage "${CURRENT_STAGE_ID:-unknown}" \
                --iteration "0" \
                --activity "$(get_stage_description "${CURRENT_STAGE_ID:-}" 2>/dev/null || echo "Running pipeline")" 2>/dev/null || true
            sleep 30
        done
    ) >/dev/null 2>&1 &
    HEARTBEAT_PID=$!
}

stop_heartbeat() {
    if [[ -n "${HEARTBEAT_PID:-}" ]]; then
        kill "$HEARTBEAT_PID" 2>/dev/null || true
        wait "$HEARTBEAT_PID" 2>/dev/null || true
        "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_NAME:-pipeline-$$}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ─── CI Helpers ───────────────────────────────────────────────────────────

ci_push_partial_work() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0

    local branch="shipwright/issue-${ISSUE_NUMBER}"

    # Only push if we have uncommitted changes
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git add -A 2>/dev/null || true
        git commit -m "WIP: partial pipeline progress for #${ISSUE_NUMBER}" --no-verify 2>/dev/null || true
    fi

    # Push branch (create if needed, force to overwrite previous WIP)
    git push origin "HEAD:refs/heads/$branch" --force 2>/dev/null || true
}

ci_post_stage_event() {
    [[ "${CI_MODE:-false}" != "true" ]] && return 0
    [[ -z "${ISSUE_NUMBER:-}" ]] && return 0
    [[ "${GH_AVAILABLE:-false}" != "true" ]] && return 0

    local stage="$1" status="$2" elapsed="${3:-0s}"
    local comment="<!-- SHIPWRIGHT-STAGE: ${stage}:${status}:${elapsed} -->"
    gh issue comment "$ISSUE_NUMBER" --body "$comment" 2>/dev/null || true
}

# ─── Signal Handling ───────────────────────────────────────────────────────

cleanup_on_exit() {
    [[ "${_cleanup_done:-}" == "true" ]] && return 0
    _cleanup_done=true
    local exit_code=$?

    # Stop heartbeat writer
    stop_heartbeat

    # Save state if we were running
    if [[ "$PIPELINE_STATUS" == "running" && -n "$STATE_FILE" ]]; then
        PIPELINE_STATUS="interrupted"
        UPDATED_AT="$(now_iso)"
        write_state 2>/dev/null || true
        echo ""
        warn "Pipeline interrupted — state saved."
        echo -e "  Resume: ${DIM}shipwright pipeline resume${RESET}"

        # Push partial work in CI mode so retries can pick it up
        ci_push_partial_work
    fi

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == "true" ]]; then
        git stash pop --quiet 2>/dev/null || true
    fi

    # Cancel lingering in_progress GitHub Check Runs
    pipeline_cancel_check_runs 2>/dev/null || true

    # Update GitHub
    if [[ -n "${ISSUE_NUMBER:-}" && "${GH_AVAILABLE:-false}" == "true" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "⏸️ **Pipeline interrupted** at stage: ${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true
    fi

    exit "$exit_code"
}

trap cleanup_on_exit SIGINT SIGTERM

# ─── Pre-flight Validation ─────────────────────────────────────────────────

preflight_checks() {
    local errors=0

    echo -e "${PURPLE}${BOLD}━━━ Pre-flight Checks ━━━${RESET}"
    echo ""

    # 1. Required tools
    local required_tools=("git" "jq")
    local optional_tools=("gh" "claude" "bc" "curl")

    for tool in "${required_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${RED}✗${RESET} $tool ${RED}(required)${RESET}"
            errors=$((errors + 1))
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            echo -e "  ${GREEN}✓${RESET} $tool"
        else
            echo -e "  ${DIM}○${RESET} $tool ${DIM}(optional — some features disabled)${RESET}"
        fi
    done

    # 2. Git state
    echo ""
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Inside git repo"
    else
        echo -e "  ${RED}✗${RESET} Not inside a git repository"
        errors=$((errors + 1))
    fi

    # Check for uncommitted changes — offer to stash
    local dirty_files
    dirty_files=$(git status --porcelain 2>/dev/null | wc -l | xargs)
    if [[ "$dirty_files" -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${RESET} $dirty_files uncommitted change(s)"
        if [[ "$SKIP_GATES" == "true" ]]; then
            info "Auto-stashing uncommitted changes..."
            git stash push -m "sw-pipeline: auto-stash before pipeline" --quiet 2>/dev/null && STASHED_CHANGES=true
            if [[ "$STASHED_CHANGES" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Changes stashed (will restore on exit)"
            fi
        else
            echo -e "    ${DIM}Tip: Use --skip-gates to auto-stash, or commit/stash manually${RESET}"
        fi
    else
        echo -e "  ${GREEN}✓${RESET} Working tree clean"
    fi

    # Check if base branch exists
    if git rev-parse --verify "$BASE_BRANCH" &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Base branch: $BASE_BRANCH"
    else
        echo -e "  ${RED}✗${RESET} Base branch not found: $BASE_BRANCH"
        errors=$((errors + 1))
    fi

    # 3. GitHub auth (if gh available and not disabled)
    if [[ "$NO_GITHUB" != "true" ]] && command -v gh &>/dev/null; then
        if gh auth status &>/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${RESET} GitHub authenticated"
        else
            echo -e "  ${YELLOW}⚠${RESET} GitHub not authenticated (features disabled)"
        fi
    fi

    # 4. Claude CLI
    if command -v claude &>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Claude CLI available"
    else
        echo -e "  ${RED}✗${RESET} Claude CLI not found — plan/build stages will fail"
        errors=$((errors + 1))
    fi

    # 5. sw loop (needed for build stage)
    if [[ -x "$SCRIPT_DIR/sw-loop.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} shipwright loop available"
    else
        echo -e "  ${RED}✗${RESET} sw-loop.sh not found at $SCRIPT_DIR"
        errors=$((errors + 1))
    fi

    # 6. Disk space check (warn if < 1GB free)
    local free_space_kb
    free_space_kb=$(df -k "$PROJECT_ROOT" 2>/dev/null | tail -1 | awk '{print $4}')
    if [[ -n "$free_space_kb" ]] && [[ "$free_space_kb" -lt 1048576 ]] 2>/dev/null; then
        echo -e "  ${YELLOW}⚠${RESET} Low disk space: $(( free_space_kb / 1024 ))MB free"
    fi

    echo ""

    if [[ "$errors" -gt 0 ]]; then
        error "Pre-flight failed: $errors error(s)"
        return 1
    fi

    success "Pre-flight passed"
    echo ""
    return 0
}

# ─── Notification Helpers ──────────────────────────────────────────────────

notify() {
    local title="$1" message="$2" level="${3:-info}"
    local emoji
    case "$level" in
        success) emoji="✅" ;;
        error)   emoji="❌" ;;
        warn)    emoji="⚠️" ;;
        *)       emoji="🔔" ;;
    esac

    # Slack webhook
    if [[ -n "${SLACK_WEBHOOK:-}" ]]; then
        local payload
        payload=$(jq -n \
            --arg text "${emoji} *${title}*\n${message}" \
            '{text: $text}')
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$SLACK_WEBHOOK" >/dev/null 2>&1 || true
    fi

    # Custom webhook (env var SHIPWRIGHT_WEBHOOK_URL, with CCT_WEBHOOK_URL fallback)
    local _webhook_url="${SHIPWRIGHT_WEBHOOK_URL:-${CCT_WEBHOOK_URL:-}}"
    if [[ -n "$_webhook_url" ]]; then
        local payload
        payload=$(jq -n \
            --arg title "$title" --arg message "$message" \
            --arg level "$level" --arg pipeline "${PIPELINE_NAME:-}" \
            --arg goal "${GOAL:-}" --arg stage "${CURRENT_STAGE_ID:-}" \
            '{title:$title, message:$message, level:$level, pipeline:$pipeline, goal:$goal, stage:$stage}')
        curl -sf -X POST -H 'Content-Type: application/json' \
            -d "$payload" "$_webhook_url" >/dev/null 2>&1 || true
    fi
}

# ─── GitHub Integration Helpers ─────────────────────────────────────────────

gh_init() {
    if [[ "$NO_GITHUB" == "true" ]]; then
        GH_AVAILABLE=false
        return
    fi

    if ! command -v gh &>/dev/null; then
        GH_AVAILABLE=false
        warn "gh CLI not found — GitHub integration disabled"
        return
    fi

    # Check if authenticated
    if ! gh auth status &>/dev/null 2>&1; then
        GH_AVAILABLE=false
        warn "gh not authenticated — GitHub integration disabled"
        return
    fi

    # Detect repo owner/name from git remote
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null || true)
    if [[ -n "$remote_url" ]]; then
        # Handle SSH: git@github.com:owner/repo.git
        # Handle HTTPS: https://github.com/owner/repo.git
        REPO_OWNER=$(echo "$remote_url" | sed -E 's#(.*github\.com[:/])([^/]+)/.*#\2#')
        REPO_NAME=$(echo "$remote_url" | sed -E 's#.*/([^/]+)(\.git)?$#\1#' | sed 's/\.git$//')
    fi

    if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        GH_AVAILABLE=true
        info "GitHub: ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        GH_AVAILABLE=false
        warn "Could not detect GitHub repo — GitHub integration disabled"
    fi
}

# Post or update a comment on a GitHub issue
# Usage: gh_comment_issue <issue_number> <body>
gh_comment_issue() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    gh issue comment "$issue_num" --body "$body" 2>/dev/null || true
}

# Post a progress-tracking comment and save its ID for later updates
# Usage: gh_post_progress <issue_number> <body>
gh_post_progress() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" body="$2"
    local result
    result=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${issue_num}/comments" \
        -f body="$body" --jq '.id' 2>/dev/null) || true
    if [[ -n "$result" && "$result" != "null" ]]; then
        PROGRESS_COMMENT_ID="$result"
    fi
}

# Update an existing progress comment by ID
# Usage: gh_update_progress <body>
gh_update_progress() {
    [[ "$GH_AVAILABLE" != "true" || -z "$PROGRESS_COMMENT_ID" ]] && return 0
    local body="$1"
    gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${PROGRESS_COMMENT_ID}" \
        -X PATCH -f body="$body" 2>/dev/null || true
}

# Add labels to an issue or PR
# Usage: gh_add_labels <issue_number> <label1,label2,...>
gh_add_labels() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" labels="$2"
    [[ -z "$labels" ]] && return 0
    gh issue edit "$issue_num" --add-label "$labels" 2>/dev/null || true
}

# Remove a label from an issue
# Usage: gh_remove_label <issue_number> <label>
gh_remove_label() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1" label="$2"
    gh issue edit "$issue_num" --remove-label "$label" 2>/dev/null || true
}

# Self-assign an issue
# Usage: gh_assign_self <issue_number>
gh_assign_self() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    gh issue edit "$issue_num" --add-assignee "@me" 2>/dev/null || true
}

# Get full issue metadata as JSON
# Usage: gh_get_issue_meta <issue_number>
gh_get_issue_meta() {
    [[ "$GH_AVAILABLE" != "true" ]] && return 0
    local issue_num="$1"
    gh issue view "$issue_num" --json title,body,labels,milestone,assignees,comments,number,state 2>/dev/null || true
}

# Build a progress table for GitHub comment
# Usage: gh_build_progress_body
gh_build_progress_body() {
    local body="## 🤖 Pipeline Progress — \`${PIPELINE_NAME}\`

**Delivering:** ${GOAL}

| Stage | Status | Duration | |
|-------|--------|----------|-|"

    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null)
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')

        if [[ "$enabled" != "true" ]]; then
            body="${body}
| ${id} | ⏭️ skipped | — | |"
            continue
        fi

        local sstatus
        sstatus=$(get_stage_status "$id")
        local duration
        duration=$(get_stage_timing "$id")

        local icon detail_col
        case "$sstatus" in
            complete)  icon="✅"; detail_col="" ;;
            running)   icon="🔄"; detail_col=$(get_stage_description "$id") ;;
            failed)    icon="❌"; detail_col="" ;;
            *)         icon="⬜"; detail_col=$(get_stage_description "$id") ;;
        esac

        body="${body}
| ${id} | ${icon} ${sstatus:-pending} | ${duration:-—} | ${detail_col} |"
    done 3<<< "$stages"

    body="${body}

**Branch:** \`${GIT_BRANCH}\`"

    [[ -n "${GITHUB_ISSUE:-}" ]] && body="${body}
**Issue:** ${GITHUB_ISSUE}"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
        body="${body}
**Elapsed:** ${total_dur}"
    fi

    # Artifacts section
    local artifacts=""
    [[ -f "$ARTIFACTS_DIR/plan.md" ]] && artifacts="${artifacts}[Plan](.claude/pipeline-artifacts/plan.md)"
    [[ -f "$ARTIFACTS_DIR/design.md" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}[Design](.claude/pipeline-artifacts/design.md)"; }
    [[ -n "${PR_NUMBER:-}" ]] && { [[ -n "$artifacts" ]] && artifacts="${artifacts} · "; artifacts="${artifacts}PR #${PR_NUMBER}"; }
    [[ -n "$artifacts" ]] && body="${body}

📎 **Artifacts:** ${artifacts}"

    body="${body}

---
_Updated: $(now_iso) · shipwright pipeline_"
    echo "$body"
}

# Push a page to the GitHub wiki
# Usage: gh_wiki_page <title> <content>
gh_wiki_page() {
    local title="$1" content="$2"
    $GH_AVAILABLE || return 0
    $NO_GITHUB && return 0
    local wiki_dir="$ARTIFACTS_DIR/wiki"
    if [[ ! -d "$wiki_dir" ]]; then
        git clone "https://github.com/${REPO_OWNER}/${REPO_NAME}.wiki.git" "$wiki_dir" 2>/dev/null || {
            info "Wiki not initialized — skipping wiki update"
            return 0
        }
    fi
    echo "$content" > "$wiki_dir/${title}.md"
    ( cd "$wiki_dir" && git add -A && git commit -m "Pipeline: update $title" && git push ) 2>/dev/null || true
}

# ─── Auto-Detection ─────────────────────────────────────────────────────────

# Detect the test command from project files
detect_test_cmd() {
    local root="$PROJECT_ROOT"

    # Node.js: check package.json scripts
    if [[ -f "$root/package.json" ]]; then
        local has_test
        has_test=$(jq -r '.scripts.test // ""' "$root/package.json" 2>/dev/null)
        if [[ -n "$has_test" && "$has_test" != "null" && "$has_test" != *"no test specified"* ]]; then
            # Detect package manager
            if [[ -f "$root/pnpm-lock.yaml" ]]; then
                echo "pnpm test"; return
            elif [[ -f "$root/yarn.lock" ]]; then
                echo "yarn test"; return
            elif [[ -f "$root/bun.lockb" ]]; then
                echo "bun test"; return
            else
                echo "npm test"; return
            fi
        fi
    fi

    # Python: check for pytest, unittest
    if [[ -f "$root/pytest.ini" || -f "$root/pyproject.toml" || -f "$root/setup.py" ]]; then
        if [[ -f "$root/pyproject.toml" ]] && grep -q "pytest" "$root/pyproject.toml" 2>/dev/null; then
            echo "pytest"; return
        elif [[ -d "$root/tests" ]]; then
            echo "pytest"; return
        fi
    fi

    # Rust
    if [[ -f "$root/Cargo.toml" ]]; then
        echo "cargo test"; return
    fi

    # Go
    if [[ -f "$root/go.mod" ]]; then
        echo "go test ./..."; return
    fi

    # Ruby
    if [[ -f "$root/Gemfile" ]]; then
        if grep -q "rspec" "$root/Gemfile" 2>/dev/null; then
            echo "bundle exec rspec"; return
        fi
        echo "bundle exec rake test"; return
    fi

    # Java/Kotlin (Maven)
    if [[ -f "$root/pom.xml" ]]; then
        echo "mvn test"; return
    fi

    # Java/Kotlin (Gradle)
    if [[ -f "$root/build.gradle" || -f "$root/build.gradle.kts" ]]; then
        echo "./gradlew test"; return
    fi

    # Makefile
    if [[ -f "$root/Makefile" ]] && grep -q "^test:" "$root/Makefile" 2>/dev/null; then
        echo "make test"; return
    fi

    # Fallback
    echo ""
}

# Detect project language/framework
detect_project_lang() {
    local root="$PROJECT_ROOT"
    local detected=""

    # Fast heuristic detection (grep-based)
    if [[ -f "$root/package.json" ]]; then
        if grep -q "typescript" "$root/package.json" 2>/dev/null; then
            detected="typescript"
        elif grep -q "\"next\"" "$root/package.json" 2>/dev/null; then
            detected="nextjs"
        elif grep -q "\"react\"" "$root/package.json" 2>/dev/null; then
            detected="react"
        else
            detected="nodejs"
        fi
    elif [[ -f "$root/Cargo.toml" ]]; then
        detected="rust"
    elif [[ -f "$root/go.mod" ]]; then
        detected="go"
    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then
        detected="python"
    elif [[ -f "$root/Gemfile" ]]; then
        detected="ruby"
    elif [[ -f "$root/pom.xml" || -f "$root/build.gradle" ]]; then
        detected="java"
    else
        detected="unknown"
    fi

    # Intelligence: holistic analysis for polyglot/monorepo detection
    if [[ "$detected" == "unknown" ]] && type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null; then
        local config_files
        config_files=$(ls "$root" 2>/dev/null | grep -E '\.(json|toml|yaml|yml|xml|gradle|lock|mod)$' | head -15)
        if [[ -n "$config_files" ]]; then
            local ai_lang
            ai_lang=$(claude --print --output-format text -p "Based on these config files in a project root, what is the primary language/framework? Reply with ONE word (e.g., typescript, python, rust, go, java, ruby, nodejs):

Files: ${config_files}" --model haiku < /dev/null 2>/dev/null || true)
            ai_lang=$(echo "$ai_lang" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$ai_lang" in
                typescript|python|rust|go|java|ruby|nodejs|react|nextjs|kotlin|swift|elixir|scala)
                    detected="$ai_lang" ;;
            esac
        fi
    fi

    echo "$detected"
}

# Detect likely reviewers from CODEOWNERS or git log
detect_reviewers() {
    local root="$PROJECT_ROOT"

    # Check CODEOWNERS — common paths first, then broader search
    local codeowners=""
    for f in "$root/.github/CODEOWNERS" "$root/CODEOWNERS" "$root/docs/CODEOWNERS"; do
        if [[ -f "$f" ]]; then
            codeowners="$f"
            break
        fi
    done
    # Broader search if not found at common locations
    if [[ -z "$codeowners" ]]; then
        codeowners=$(find "$root" -maxdepth 3 -name "CODEOWNERS" -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$codeowners" ]]; then
        # Extract GitHub usernames from CODEOWNERS (lines like: * @user1 @user2)
        local owners
        owners=$(grep -oE '@[a-zA-Z0-9_-]+' "$codeowners" 2>/dev/null | sed 's/@//' | sort -u | head -3 | tr '\n' ',')
        owners="${owners%,}"  # trim trailing comma
        if [[ -n "$owners" ]]; then
            echo "$owners"
            return
        fi
    fi

    # Fallback: try to extract GitHub usernames from recent commit emails
    # Format: user@users.noreply.github.com → user, or noreply+user@... → user
    local current_user
    current_user=$(gh api user --jq '.login' 2>/dev/null || true)
    local contributors
    contributors=$(git log --format='%aE' -100 2>/dev/null | \
        grep -oE '[a-zA-Z0-9_-]+@users\.noreply\.github\.com' | \
        sed 's/@users\.noreply\.github\.com//' | sed 's/^[0-9]*+//' | \
        sort | uniq -c | sort -rn | \
        awk '{print $NF}' | \
        grep -v "^${current_user:-___}$" 2>/dev/null | \
        head -2 | tr '\n' ',')
    contributors="${contributors%,}"
    echo "$contributors"
}

# Get branch prefix from task type — checks git history for conventions first
branch_prefix_for_type() {
    local task_type="$1"

    # Analyze recent branches for naming conventions
    local branch_prefixes
    branch_prefixes=$(git branch -r 2>/dev/null | sed 's#origin/##' | grep -oE '^[a-z]+/' | sort | uniq -c | sort -rn | head -5 || true)
    if [[ -n "$branch_prefixes" ]]; then
        local total_branches dominant_prefix dominant_count
        total_branches=$(echo "$branch_prefixes" | awk '{s+=$1} END {print s}' || echo "0")
        dominant_prefix=$(echo "$branch_prefixes" | head -1 | awk '{print $2}' | tr -d '/' || true)
        dominant_count=$(echo "$branch_prefixes" | head -1 | awk '{print $1}' || echo "0")
        # If >80% of branches use a pattern, adopt it for the matching type
        if [[ "$total_branches" -gt 5 ]] && [[ "$dominant_count" -gt 0 ]]; then
            local pct=$(( (dominant_count * 100) / total_branches ))
            if [[ "$pct" -gt 80 && -n "$dominant_prefix" ]]; then
                # Map task type to the repo's convention
                local mapped=""
                case "$task_type" in
                    bug)      mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(fix|bug|hotfix)$' | head -1 || true) ;;
                    feature)  mapped=$(echo "$branch_prefixes" | awk '{print $2}' | tr -d '/' | grep -E '^(feat|feature)$' | head -1 || true) ;;
                esac
                if [[ -n "$mapped" ]]; then
                    echo "$mapped"
                    return
                fi
            fi
        fi
    fi

    # Fallback: hardcoded mapping
    case "$task_type" in
        bug)          echo "fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "test" ;;
        security)     echo "security" ;;
        docs)         echo "docs" ;;
        devops)       echo "ci" ;;
        migration)    echo "migrate" ;;
        architecture) echo "arch" ;;
        *)            echo "feat" ;;
    esac
}

# ─── State Management ──────────────────────────────────────────────────────

PIPELINE_STATUS="pending"
CURRENT_STAGE=""
STARTED_AT=""
UPDATED_AT=""
STAGE_STATUSES=""
LOG_ENTRIES=""

save_artifact() {
    local name="$1" content="$2"
    echo "$content" > "$ARTIFACTS_DIR/$name"
}

get_stage_status() {
    local stage_id="$1"
    echo "$STAGE_STATUSES" | grep "^${stage_id}:" | cut -d: -f2 | tail -1 || true
}

set_stage_status() {
    local stage_id="$1" status="$2"
    STAGE_STATUSES=$(echo "$STAGE_STATUSES" | grep -v "^${stage_id}:" || true)
    STAGE_STATUSES="${STAGE_STATUSES}
${stage_id}:${status}"
}

# Per-stage timing
record_stage_start() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_start:$(now_epoch)"
}

record_stage_end() {
    local stage_id="$1"
    STAGE_TIMINGS="${STAGE_TIMINGS}
${stage_id}_end:$(now_epoch)"
}

get_stage_timing() {
    local stage_id="$1"
    local start_e end_e
    start_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_start:" | cut -d: -f2 | tail -1 || true)
    end_e=$(echo "$STAGE_TIMINGS" | grep "^${stage_id}_end:" | cut -d: -f2 | tail -1 || true)
    if [[ -n "$start_e" && -n "$end_e" ]]; then
        format_duration $(( end_e - start_e ))
    elif [[ -n "$start_e" ]]; then
        format_duration $(( $(now_epoch) - start_e ))
    else
        echo ""
    fi
}

get_stage_description() {
    local stage_id="$1"

    # Try to generate dynamic description from pipeline config
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        local stage_cfg
        stage_cfg=$(jq -c --arg id "$stage_id" '.stages[] | select(.id == $id) | .config // {}' "$PIPELINE_CONFIG" 2>/dev/null || echo "{}")
        case "$stage_id" in
            test)
                local cfg_test_cmd cfg_cov_min
                cfg_test_cmd=$(echo "$stage_cfg" | jq -r '.test_cmd // empty' 2>/dev/null || true)
                cfg_cov_min=$(echo "$stage_cfg" | jq -r '.coverage_min // empty' 2>/dev/null || true)
                if [[ -n "$cfg_test_cmd" ]]; then
                    echo "Running ${cfg_test_cmd}${cfg_cov_min:+ with ${cfg_cov_min}% coverage gate}"
                    return
                fi
                ;;
            build)
                local cfg_max_iter cfg_model
                cfg_max_iter=$(echo "$stage_cfg" | jq -r '.max_iterations // empty' 2>/dev/null || true)
                cfg_model=$(jq -r '.defaults.model // empty' "$PIPELINE_CONFIG" 2>/dev/null || true)
                if [[ -n "$cfg_max_iter" ]]; then
                    echo "Building with ${cfg_max_iter} max iterations${cfg_model:+ using ${cfg_model}}"
                    return
                fi
                ;;
            monitor)
                local cfg_dur cfg_thresh
                cfg_dur=$(echo "$stage_cfg" | jq -r '.duration_minutes // empty' 2>/dev/null || true)
                cfg_thresh=$(echo "$stage_cfg" | jq -r '.error_threshold // empty' 2>/dev/null || true)
                if [[ -n "$cfg_dur" ]]; then
                    echo "Monitoring for ${cfg_dur}m${cfg_thresh:+ (threshold: ${cfg_thresh} errors)}"
                    return
                fi
                ;;
        esac
    fi

    # Static fallback descriptions
    case "$stage_id" in
        intake)           echo "Extracting requirements and auto-detecting project setup" ;;
        plan)             echo "Creating implementation plan with architecture decisions" ;;
        design)           echo "Designing interfaces, data models, and API contracts" ;;
        build)            echo "Writing production code with self-healing iteration" ;;
        test)             echo "Running test suite and validating coverage" ;;
        review)           echo "Code quality, security audit, performance review" ;;
        compound_quality) echo "Adversarial testing, E2E validation, DoD checklist" ;;
        pr)               echo "Creating pull request with CI integration" ;;
        merge)            echo "Merging PR with branch cleanup" ;;
        deploy)           echo "Deploying to staging/production" ;;
        validate)         echo "Smoke tests and health checks post-deploy" ;;
        monitor)          echo "Production monitoring with auto-rollback" ;;
        *)                echo "" ;;
    esac
}

# Build inline stage progress string (e.g. "intake:complete plan:running test:pending")
build_stage_progress() {
    local progress=""
    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG" 2>/dev/null) || return 0
    while IFS= read -r -u 3 stage; do
        local id enabled
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        [[ "$enabled" != "true" ]] && continue
        local sstatus
        sstatus=$(get_stage_status "$id")
        sstatus="${sstatus:-pending}"
        if [[ -n "$progress" ]]; then
            progress="${progress} ${id}:${sstatus}"
        else
            progress="${id}:${sstatus}"
        fi
    done 3<<< "$stages"
    echo "$progress"
}

update_status() {
    local status="$1" stage="$2"
    PIPELINE_STATUS="$status"
    CURRENT_STAGE="$stage"
    UPDATED_AT="$(now_iso)"
    write_state
}

mark_stage_complete() {
    local stage_id="$1"
    record_stage_end "$stage_id"
    set_stage_status "$stage_id" "complete"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "complete (${timing})"
    write_state

    # Update GitHub progress comment
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"

        # Notify tracker (Linear/Jira) of stage completion
        local stage_desc
        stage_desc=$(get_stage_description "$stage_id")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_complete" "$ISSUE_NUMBER" \
            "${stage_id}|${timing}|${stage_desc}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "complete" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update &>/dev/null 2>&1; then
        gh_checks_stage_update "$stage_id" "completed" "success" "Stage $stage_id: ${timing}" 2>/dev/null || true
    fi
}

mark_stage_failed() {
    local stage_id="$1"
    record_stage_end "$stage_id"
    set_stage_status "$stage_id" "failed"
    local timing
    timing=$(get_stage_timing "$stage_id")
    log_stage "$stage_id" "failed (${timing})"
    write_state

    # Update GitHub progress + comment failure
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
        gh_comment_issue "$ISSUE_NUMBER" "❌ Pipeline failed at stage **${stage_id}** after ${timing}.

\`\`\`
$(tail -5 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null || echo 'No log available')
\`\`\`"

        # Notify tracker (Linear/Jira) of stage failure
        local error_context
        error_context=$(tail -5 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null || echo "No log")
        "$SCRIPT_DIR/sw-tracker.sh" notify "stage_failed" "$ISSUE_NUMBER" \
            "${stage_id}|${error_context}" 2>/dev/null || true

        # Post structured stage event for CI sweep/retry intelligence
        ci_post_stage_event "$stage_id" "failed" "$timing"
    fi

    # Update GitHub Check Run for this stage
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update &>/dev/null 2>&1; then
        local fail_summary
        fail_summary=$(tail -3 "$ARTIFACTS_DIR/${stage_id}"*.log 2>/dev/null | head -c 500 || echo "Stage $stage_id failed")
        gh_checks_stage_update "$stage_id" "completed" "failure" "$fail_summary" 2>/dev/null || true
    fi
}

log_stage() {
    local stage_id="$1" message="$2"
    local timestamp
    timestamp=$(date +"%H:%M:%S")
    LOG_ENTRIES="${LOG_ENTRIES}
### ${stage_id} (${timestamp})
${message}
"
}

initialize_state() {
    PIPELINE_STATUS="running"
    PIPELINE_START_EPOCH="$(now_epoch)"
    STARTED_AT="$(now_iso)"
    UPDATED_AT="$(now_iso)"
    STAGE_STATUSES=""
    STAGE_TIMINGS=""
    LOG_ENTRIES=""
    # Clear per-run tracking files
    rm -f "$ARTIFACTS_DIR/model-routing.log" "$ARTIFACTS_DIR/.plan-failure-sig.txt"
    write_state
}

write_state() {
    [[ -z "${STATE_FILE:-}" || -z "${ARTIFACTS_DIR:-}" ]] && return 0
    local stages_yaml=""
    while IFS=: read -r sid sstatus; do
        [[ -z "$sid" ]] && continue
        stages_yaml="${stages_yaml}  ${sid}: ${sstatus}
"
    done <<< "$STAGE_STATUSES"

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Stage description and progress for dashboard enrichment
    local cur_stage_desc=""
    if [[ -n "${CURRENT_STAGE:-}" ]]; then
        cur_stage_desc=$(get_stage_description "$CURRENT_STAGE")
    fi
    local stage_progress=""
    if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
        stage_progress=$(build_stage_progress)
    fi

    cat > "$STATE_FILE" <<EOF
---
pipeline: $PIPELINE_NAME
goal: "$GOAL"
status: $PIPELINE_STATUS
issue: "${GITHUB_ISSUE:-}"
branch: "${GIT_BRANCH:-}"
template: "${TASK_TYPE:+$(template_for_type "$TASK_TYPE")}"
current_stage: $CURRENT_STAGE
current_stage_description: "${cur_stage_desc}"
stage_progress: "${stage_progress}"
started_at: ${STARTED_AT:-$(now_iso)}
updated_at: $(now_iso)
elapsed: ${total_dur:-0s}
pr_number: ${PR_NUMBER:-}
progress_comment_id: ${PROGRESS_COMMENT_ID:-}
stages:
${stages_yaml}---

## Log
$LOG_ENTRIES
EOF
}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No pipeline state found at $STATE_FILE"
        echo -e "  Start a new pipeline: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        exit 1
    fi

    info "Resuming pipeline from $STATE_FILE"

    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)            PIPELINE_NAME="$(echo "${line#pipeline:}" | xargs)" ;;
                goal:*)                GOAL="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                status:*)              PIPELINE_STATUS="$(echo "${line#status:}" | xargs)" ;;
                issue:*)               GITHUB_ISSUE="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                branch:*)              GIT_BRANCH="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*)       CURRENT_STAGE="$(echo "${line#current_stage:}" | xargs)" ;;
                current_stage_description:*) ;; # computed field — skip on resume
                stage_progress:*)      ;; # computed field — skip on resume
                started_at:*)          STARTED_AT="$(echo "${line#started_at:}" | xargs)" ;;
                pr_number:*)           PR_NUMBER="$(echo "${line#pr_number:}" | xargs)" ;;
                progress_comment_id:*) PROGRESS_COMMENT_ID="$(echo "${line#progress_comment_id:}" | xargs)" ;;
                "  "*)
                    local trimmed
                    trimmed="$(echo "$line" | xargs)"
                    if [[ "$trimmed" == *":"* ]]; then
                        local sid="${trimmed%%:*}"
                        local sst="${trimmed#*: }"
                        [[ -n "$sid" && "$sid" != "stages" ]] && STAGE_STATUSES="${STAGE_STATUSES}
${sid}:${sst}"
                    fi
                    ;;
            esac
        fi
    done < "$STATE_FILE"

    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -n "$GITHUB_ISSUE" && "$GITHUB_ISSUE" =~ ^#([0-9]+)$ ]]; then
        ISSUE_NUMBER="${BASH_REMATCH[1]}"
    fi

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$PIPELINE_STATUS" == "complete" ]]; then
        warn "Pipeline already completed. Start a new one."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "aborted" ]]; then
        warn "Pipeline was aborted. Start a new one or edit the state file."
        exit 0
    fi

    if [[ "$PIPELINE_STATUS" == "interrupted" ]]; then
        info "Resuming from interruption..."
    fi

    if [[ -n "$GIT_BRANCH" ]]; then
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    fi

    PIPELINE_START_EPOCH="$(now_epoch)"
    gh_init
    load_pipeline_config
    PIPELINE_STATUS="running"
    success "Resumed pipeline: ${BOLD}$PIPELINE_NAME${RESET} — stage: $CURRENT_STAGE"
}

# ─── Task Type Detection ───────────────────────────────────────────────────

detect_task_type() {
    local goal="$1"

    # Intelligence: Claude classification with confidence score
    if type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null; then
        local ai_result
        ai_result=$(claude --print --output-format text -p "Classify this task into exactly ONE category. Reply in format: CATEGORY|CONFIDENCE (0-100)

Categories: bug, refactor, testing, security, docs, devops, migration, architecture, feature

Task: ${goal}" --model haiku < /dev/null 2>/dev/null || true)
        if [[ -n "$ai_result" ]]; then
            local ai_type ai_conf
            ai_type=$(echo "$ai_result" | head -1 | cut -d'|' -f1 | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            ai_conf=$(echo "$ai_result" | head -1 | cut -d'|' -f2 | grep -oE '[0-9]+' | head -1 || echo "0")
            # Use AI classification if confidence >= 70
            case "$ai_type" in
                bug|refactor|testing|security|docs|devops|migration|architecture|feature)
                    if [[ "${ai_conf:-0}" -ge 70 ]] 2>/dev/null; then
                        echo "$ai_type"
                        return
                    fi
                    ;;
            esac
        fi
    fi

    # Fallback: keyword matching
    local lower
    lower=$(echo "$goal" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *fix*|*bug*|*broken*|*error*|*crash*)     echo "bug" ;;
        *refactor*|*clean*|*reorganize*|*extract*) echo "refactor" ;;
        *test*|*coverage*|*spec*)                  echo "testing" ;;
        *security*|*audit*|*vuln*|*cve*)           echo "security" ;;
        *doc*|*readme*|*guide*)                    echo "docs" ;;
        *deploy*|*ci*|*pipeline*|*docker*|*infra*) echo "devops" ;;
        *migrate*|*migration*|*schema*)            echo "migration" ;;
        *architect*|*design*|*rfc*|*adr*)          echo "architecture" ;;
        *)                                          echo "feature" ;;
    esac
}

template_for_type() {
    case "$1" in
        bug)          echo "bug-fix" ;;
        refactor)     echo "refactor" ;;
        testing)      echo "testing" ;;
        security)     echo "security-audit" ;;
        docs)         echo "documentation" ;;
        devops)       echo "devops" ;;
        migration)    echo "migration" ;;
        architecture) echo "architecture" ;;
        *)            echo "feature-dev" ;;
    esac
}

# ─── Stage Preview ──────────────────────────────────────────────────────────

show_stage_preview() {
    local stage_id="$1"
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Stage: ${stage_id} ━━━${RESET}"
    case "$stage_id" in
        intake)   echo -e "  Fetch issue, detect task type, create branch, self-assign" ;;
        plan)     echo -e "  Generate plan via Claude, post task checklist to issue" ;;
        design)   echo -e "  Generate Architecture Decision Record (ADR), evaluate alternatives" ;;
        build)    echo -e "  Delegate to ${CYAN}shipwright loop${RESET} for autonomous building" ;;
        test)     echo -e "  Run test suite and check coverage" ;;
        review)   echo -e "  AI code review on the diff, post findings" ;;
        pr)       echo -e "  Create GitHub PR with labels, reviewers, milestone" ;;
        merge)    echo -e "  Wait for CI checks, merge PR, optionally delete branch" ;;
        deploy)   echo -e "  Deploy to staging/production with rollback" ;;
        validate) echo -e "  Smoke tests, health checks, close issue" ;;
        monitor)  echo -e "  Post-deploy monitoring, health checks, auto-rollback" ;;
    esac
    echo ""
}

# ─── Stage Functions ────────────────────────────────────────────────────────

stage_intake() {
    CURRENT_STAGE_ID="intake"
    local project_lang
    project_lang=$(detect_project_lang)
    info "Project: ${BOLD}$project_lang${RESET}"

    # 1. Fetch issue metadata if --issue provided
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local meta
        meta=$(gh_get_issue_meta "$ISSUE_NUMBER")

        if [[ -n "$meta" ]]; then
            GOAL=$(echo "$meta" | jq -r '.title // ""')
            ISSUE_BODY=$(echo "$meta" | jq -r '.body // ""')
            ISSUE_LABELS=$(echo "$meta" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || true)
            ISSUE_MILESTONE=$(echo "$meta" | jq -r '.milestone.title // ""' 2>/dev/null || true)
            ISSUE_ASSIGNEES=$(echo "$meta" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null || true)
            [[ "$ISSUE_MILESTONE" == "null" ]] && ISSUE_MILESTONE=""
            [[ "$ISSUE_LABELS" == "null" ]] && ISSUE_LABELS=""
        else
            # Fallback: just get title
            GOAL=$(gh issue view "$ISSUE_NUMBER" --json title -q .title 2>/dev/null) || {
                error "Failed to fetch issue #$ISSUE_NUMBER"
                return 1
            }
        fi

        GITHUB_ISSUE="#$ISSUE_NUMBER"
        info "Issue #$ISSUE_NUMBER: ${BOLD}$GOAL${RESET}"

        if [[ -n "$ISSUE_LABELS" ]]; then
            info "Labels: ${DIM}$ISSUE_LABELS${RESET}"
        fi
        if [[ -n "$ISSUE_MILESTONE" ]]; then
            info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
        fi

        # Self-assign
        gh_assign_self "$ISSUE_NUMBER"

        # Add in-progress label
        gh_add_labels "$ISSUE_NUMBER" "pipeline/in-progress"
    fi

    # 2. Detect task type
    TASK_TYPE=$(detect_task_type "$GOAL")
    local suggested_template
    suggested_template=$(template_for_type "$TASK_TYPE")
    info "Detected: ${BOLD}$TASK_TYPE${RESET} → team template: ${CYAN}$suggested_template${RESET}"

    # 3. Auto-detect test command if not provided
    if [[ -z "$TEST_CMD" ]]; then
        TEST_CMD=$(detect_test_cmd)
        if [[ -n "$TEST_CMD" ]]; then
            info "Auto-detected test: ${DIM}$TEST_CMD${RESET}"
        fi
    fi

    # 4. Create branch with smart prefix
    local prefix
    prefix=$(branch_prefix_for_type "$TASK_TYPE")
    local slug
    slug=$(echo "$GOAL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-40)
    slug="${slug%-}"
    [[ -n "$ISSUE_NUMBER" ]] && slug="${slug}-${ISSUE_NUMBER}"
    GIT_BRANCH="${prefix}/${slug}"

    git checkout -b "$GIT_BRANCH" 2>/dev/null || {
        info "Branch $GIT_BRANCH exists, checking out"
        git checkout "$GIT_BRANCH" 2>/dev/null || true
    }
    success "Branch: ${BOLD}$GIT_BRANCH${RESET}"

    # 5. Post initial progress comment on GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_post_progress "$ISSUE_NUMBER" "$body"
    fi

    # 6. Save artifacts
    save_artifact "intake.json" "$(jq -n \
        --arg goal "$GOAL" --arg type "$TASK_TYPE" \
        --arg template "$suggested_template" --arg branch "$GIT_BRANCH" \
        --arg issue "${GITHUB_ISSUE:-}" --arg lang "$project_lang" \
        --arg test_cmd "${TEST_CMD:-}" --arg labels "${ISSUE_LABELS:-}" \
        --arg milestone "${ISSUE_MILESTONE:-}" --arg body "${ISSUE_BODY:-}" \
        '{goal:$goal, type:$type, template:$template, branch:$branch,
          issue:$issue, language:$lang, test_cmd:$test_cmd,
          labels:$labels, milestone:$milestone, body:$body}')"

    log_stage "intake" "Goal: $GOAL
Type: $TASK_TYPE → template: $suggested_template
Branch: $GIT_BRANCH
Language: $project_lang
Test cmd: ${TEST_CMD:-none detected}"
}

stage_plan() {
    CURRENT_STAGE_ID="plan"
    local plan_file="$ARTIFACTS_DIR/plan.md"

    if ! command -v claude &>/dev/null; then
        error "Claude CLI not found — cannot generate plan"
        return 1
    fi

    info "Generating implementation plan..."

    # Build rich prompt with all available context
    local plan_prompt="You are an autonomous development agent. Analyze this codebase and create a detailed implementation plan.

## Goal
${GOAL}
"

    # Add issue context
    if [[ -n "$ISSUE_BODY" ]]; then
        plan_prompt="${plan_prompt}
## Issue Description
${ISSUE_BODY}
"
    fi

    # Inject intelligence memory context for similar past plans
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local plan_memory
        plan_memory=$(intelligence_search_memory "plan stage for ${TASK_TYPE:-feature}: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        if [[ -n "$plan_memory" && "$plan_memory" != *'"results":[]'* && "$plan_memory" != *'"error"'* ]]; then
            local memory_summary
            memory_summary=$(echo "$plan_memory" | jq -r '.results[]? | "- \(.)"' 2>/dev/null | head -10 || true)
            if [[ -n "$memory_summary" ]]; then
                plan_prompt="${plan_prompt}
## Historical Context (from previous pipelines)
Previous similar issues were planned as:
${memory_summary}
"
            fi
        fi
    fi

    # Inject architecture patterns from intelligence layer
    local repo_hash_plan
    repo_hash_plan=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file_plan="${HOME}/.shipwright/memory/${repo_hash_plan}/architecture.json"
    if [[ -f "$arch_file_plan" ]]; then
        local arch_patterns
        arch_patterns=$(jq -r '
            "Language: \(.language // "unknown")",
            "Framework: \(.framework // "unknown")",
            "Patterns: \((.patterns // []) | join(", "))",
            "Rules: \((.rules // []) | join("; "))"
        ' "$arch_file_plan" 2>/dev/null || true)
        if [[ -n "$arch_patterns" ]]; then
            plan_prompt="${plan_prompt}
## Architecture Patterns
${arch_patterns}
"
        fi
    fi

    # Task-type-specific guidance
    case "${TASK_TYPE:-feature}" in
        bug)
            plan_prompt="${plan_prompt}
## Task Type: Bug Fix
Focus on: reproducing the bug, identifying root cause, minimal targeted fix, regression tests.
" ;;
        refactor)
            plan_prompt="${plan_prompt}
## Task Type: Refactor
Focus on: preserving all existing behavior, incremental changes, comprehensive test coverage.
" ;;
        security)
            plan_prompt="${plan_prompt}
## Task Type: Security
Focus on: threat modeling, OWASP top 10, input validation, authentication/authorization.
" ;;
    esac

    # Add project context
    local project_lang
    project_lang=$(detect_project_lang)
    plan_prompt="${plan_prompt}
## Project Context
- Language: ${project_lang}
- Test command: ${TEST_CMD:-not configured}
- Task type: ${TASK_TYPE:-feature}

## Required Output
Create a Markdown plan with these sections:

### Files to Modify
List every file to create or modify with full paths.

### Implementation Steps
Numbered steps in order of execution. Be specific about what code to write.

### Task Checklist
A checkbox list of discrete tasks that can be tracked:
- [ ] Task 1: Description
- [ ] Task 2: Description
(Include 5-15 tasks covering the full implementation)

### Testing Approach
How to verify the implementation works.

### Definition of Done
Checklist of completion criteria.
"

    local plan_model
    plan_model=$(jq -r --arg id "plan" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && plan_model="$MODEL"
    [[ -z "$plan_model" || "$plan_model" == "null" ]] && plan_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        plan_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-plan.log"
    claude --print --model "$plan_model" --max-turns 25 \
        "$plan_prompt" < /dev/null > "$plan_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

    if [[ ! -s "$plan_file" ]]; then
        error "Plan generation failed"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$plan_file" | xargs)
    info "Plan saved: ${DIM}$plan_file${RESET} (${line_count} lines)"

    # Extract task checklist for GitHub issue and task tracking
    local checklist
    checklist=$(sed -n '/### Task Checklist/,/^###/p' "$plan_file" 2>/dev/null | \
        grep '^\s*- \[' | head -20)

    if [[ -z "$checklist" ]]; then
        # Fallback: extract any checkbox lines
        checklist=$(grep '^\s*- \[' "$plan_file" 2>/dev/null | head -20)
    fi

    # Write local task file for Claude Code build stage
    if [[ -n "$checklist" ]]; then
        cat > "$TASKS_FILE" <<TASKS_EOF
# Pipeline Tasks — ${GOAL}

## Implementation Checklist
${checklist}

## Context
- Pipeline: ${PIPELINE_NAME}
- Branch: ${GIT_BRANCH}
- Issue: ${GITHUB_ISSUE:-none}
- Generated: $(now_iso)
TASKS_EOF
        info "Task list: ${DIM}$TASKS_FILE${RESET} ($(echo "$checklist" | wc -l | xargs) tasks)"
    fi

    # Post plan + task checklist to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local plan_summary
        plan_summary=$(head -50 "$plan_file")
        local gh_body="## 📋 Implementation Plan

<details>
<summary>Click to expand full plan (${line_count} lines)</summary>

${plan_summary}

</details>
"
        if [[ -n "$checklist" ]]; then
            gh_body="${gh_body}
## ✅ Task Checklist
${checklist}
"
        fi

        gh_body="${gh_body}
---
_Generated by \`shipwright pipeline\` at $(now_iso)_"

        gh_comment_issue "$ISSUE_NUMBER" "$gh_body"
        info "Plan posted to issue #$ISSUE_NUMBER"
    fi

    # Push plan to wiki
    gh_wiki_page "Pipeline-Plan-${ISSUE_NUMBER:-inline}" "$(<"$plan_file")"

    # Generate Claude Code task list
    local cc_tasks_file="$PROJECT_ROOT/.claude/tasks.md"
    if [[ -n "$checklist" ]]; then
        cat > "$cc_tasks_file" <<CC_TASKS_EOF
# Tasks — ${GOAL}

## Status: In Progress
Pipeline: ${PIPELINE_NAME} | Branch: ${GIT_BRANCH}

## Checklist
${checklist}

## Notes
- Generated from pipeline plan at $(now_iso)
- Pipeline will update status as tasks complete
CC_TASKS_EOF
        info "Claude Code tasks: ${DIM}$cc_tasks_file${RESET}"
    fi

    # Extract definition of done for quality gates
    sed -n '/[Dd]efinition [Oo]f [Dd]one/,/^#/p' "$plan_file" | head -20 > "$ARTIFACTS_DIR/dod.md" 2>/dev/null || true

    # ── Plan Validation Gate ──
    # Ask Claude to validate the plan before proceeding
    if command -v claude &>/dev/null && [[ -s "$plan_file" ]]; then
        local validation_attempts=0
        local max_validation_attempts=2
        local plan_valid=false

        while [[ "$validation_attempts" -lt "$max_validation_attempts" ]]; do
            validation_attempts=$((validation_attempts + 1))
            info "Validating plan (attempt ${validation_attempts}/${max_validation_attempts})..."

            # Build enriched validation prompt with learned context
            local validation_extra=""

            # Inject rejected plan history from memory
            if type intelligence_search_memory &>/dev/null 2>&1; then
                local rejected_plans
                rejected_plans=$(intelligence_search_memory "rejected plan validation failures for: ${GOAL:-}" "${HOME}/.shipwright/memory" 3 2>/dev/null) || true
                if [[ -n "$rejected_plans" ]]; then
                    validation_extra="${validation_extra}
## Previously Rejected Plans
These issues were found in past plan validations for similar tasks:
${rejected_plans}
"
                fi
            fi

            # Inject repo conventions contextually
            local claudemd="$PROJECT_ROOT/.claude/CLAUDE.md"
            if [[ -f "$claudemd" ]]; then
                local conventions_summary
                conventions_summary=$(head -100 "$claudemd" 2>/dev/null | grep -E '^##|^-|^\*' | head -15 || true)
                if [[ -n "$conventions_summary" ]]; then
                    validation_extra="${validation_extra}
## Repo Conventions
${conventions_summary}
"
                fi
            fi

            # Inject complexity estimate
            local complexity_hint=""
            if [[ -n "${INTELLIGENCE_COMPLEXITY:-}" && "${INTELLIGENCE_COMPLEXITY:-0}" -gt 0 ]]; then
                complexity_hint="This is estimated as complexity ${INTELLIGENCE_COMPLEXITY}/10. Plans for this complexity typically need ${INTELLIGENCE_COMPLEXITY} or more tasks."
            fi

            local validation_prompt="You are a plan validator. Review this implementation plan and determine if it is valid.

## Goal
${GOAL}
${complexity_hint:+
## Complexity Estimate
${complexity_hint}
}
## Plan
$(cat "$plan_file")
${validation_extra}
Evaluate:
1. Are all requirements from the goal addressed?
2. Is the plan decomposed into clear, achievable tasks?
3. Are the implementation steps specific enough to execute?

Respond with EXACTLY one of these on the first line:
VALID: true
VALID: false

Then explain your reasoning briefly."

            local validation_model="${plan_model:-opus}"
            local validation_result
            validation_result=$(claude --print --output-format text -p "$validation_prompt" --model "$validation_model" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-plan-validate.log" || true)
            parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-plan-validate.log"

            # Save validation result
            echo "$validation_result" > "$ARTIFACTS_DIR/plan-validation.md"

            if echo "$validation_result" | head -5 | grep -qi "VALID: true"; then
                success "Plan validation passed"
                plan_valid=true
                break
            fi

            warn "Plan validation failed (attempt ${validation_attempts}/${max_validation_attempts})"

            # Analyze failure mode to decide how to recover
            local failure_mode="unknown"
            local validation_lower
            validation_lower=$(echo "$validation_result" | tr '[:upper:]' '[:lower:]')
            if echo "$validation_lower" | grep -qE 'requirements? unclear|goal.*vague|ambiguous|underspecified'; then
                failure_mode="requirements_unclear"
            elif echo "$validation_lower" | grep -qE 'insufficient detail|not specific|too high.level|missing.*steps|lacks.*detail'; then
                failure_mode="insufficient_detail"
            elif echo "$validation_lower" | grep -qE 'scope too (large|broad)|too many|overly complex|break.*down'; then
                failure_mode="scope_too_large"
            fi

            emit_event "plan.validation_failure" \
                "issue=${ISSUE_NUMBER:-0}" \
                "attempt=$validation_attempts" \
                "failure_mode=$failure_mode"

            # Track repeated failures — escalate if stuck in a loop
            if [[ -f "$ARTIFACTS_DIR/.plan-failure-sig.txt" ]]; then
                local prev_sig
                prev_sig=$(cat "$ARTIFACTS_DIR/.plan-failure-sig.txt" 2>/dev/null || true)
                if [[ "$failure_mode" == "$prev_sig" && "$failure_mode" != "unknown" ]]; then
                    warn "Same validation failure mode repeated ($failure_mode) — escalating"
                    emit_event "plan.validation_escalated" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "failure_mode=$failure_mode"
                    break
                fi
            fi
            echo "$failure_mode" > "$ARTIFACTS_DIR/.plan-failure-sig.txt"

            if [[ "$validation_attempts" -lt "$max_validation_attempts" ]]; then
                info "Regenerating plan with validation feedback (mode: ${failure_mode})..."

                # Tailor regeneration prompt based on failure mode
                local failure_guidance=""
                case "$failure_mode" in
                    requirements_unclear)
                        failure_guidance="The validator found the requirements unclear. Add more specific acceptance criteria, input/output examples, and concrete success metrics." ;;
                    insufficient_detail)
                        failure_guidance="The validator found the plan lacks detail. Break each task into smaller, more specific implementation steps with exact file paths and function names." ;;
                    scope_too_large)
                        failure_guidance="The validator found the scope too large. Focus on the minimal viable implementation and defer non-essential features to follow-up tasks." ;;
                esac

                local regen_prompt="${plan_prompt}

IMPORTANT: A previous plan was rejected by validation. Issues found:
$(echo "$validation_result" | tail -20)
${failure_guidance:+
GUIDANCE: ${failure_guidance}}

Fix these issues in the new plan."

                claude --print --model "$plan_model" --max-turns 25 \
                    "$regen_prompt" < /dev/null > "$plan_file" 2>"$_token_log" || true
                parse_claude_tokens "$_token_log"

                line_count=$(wc -l < "$plan_file" | xargs)
                info "Regenerated plan: ${DIM}$plan_file${RESET} (${line_count} lines)"
            fi
        done

        if [[ "$plan_valid" != "true" ]]; then
            warn "Plan validation did not pass after ${max_validation_attempts} attempts — proceeding anyway"
        fi

        emit_event "plan.validated" \
            "issue=${ISSUE_NUMBER:-0}" \
            "valid=${plan_valid}" \
            "attempts=${validation_attempts}"
    fi

    log_stage "plan" "Generated plan.md (${line_count} lines, $(echo "$checklist" | wc -l | xargs) tasks)"
}

stage_design() {
    CURRENT_STAGE_ID="design"
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"

    if [[ ! -s "$plan_file" ]]; then
        warn "No plan found — skipping design stage"
        return 0
    fi

    if ! command -v claude &>/dev/null; then
        error "Claude CLI not found — cannot generate design"
        return 1
    fi

    info "Generating Architecture Decision Record..."

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "design stage architecture patterns for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "design" 2>/dev/null) || true
    fi

    # Inject architecture model patterns if available
    local arch_context=""
    local repo_hash
    repo_hash=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_model_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_model_file" ]]; then
        local arch_patterns
        arch_patterns=$(jq -r '
            [.patterns // [] | .[] | "- \(.name // "unnamed"): \(.description // "no description")"] | join("\n")
        ' "$arch_model_file" 2>/dev/null) || true
        local arch_layers
        arch_layers=$(jq -r '
            [.layers // [] | .[] | "- \(.name // "unnamed"): \(.path // "")"] | join("\n")
        ' "$arch_model_file" 2>/dev/null) || true
        if [[ -n "$arch_patterns" || -n "$arch_layers" ]]; then
            arch_context="Previous designs in this repo follow these patterns:
${arch_patterns:+Patterns:
${arch_patterns}
}${arch_layers:+Layers:
${arch_layers}}"
        fi
    fi

    # Inject rejected design approaches and anti-patterns from memory
    local design_antipatterns=""
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local rejected_designs
        rejected_designs=$(intelligence_search_memory "rejected design approaches anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 3 2>/dev/null) || true
        if [[ -n "$rejected_designs" ]]; then
            design_antipatterns="
## Rejected Approaches (from past reviews)
These design approaches were rejected in past reviews. Avoid repeating them:
${rejected_designs}
"
        fi
    fi

    # Build design prompt with plan + project context
    local project_lang
    project_lang=$(detect_project_lang)

    local design_prompt="You are a senior software architect. Review the implementation plan below and produce an Architecture Decision Record (ADR).

## Goal
${GOAL}

## Implementation Plan
$(cat "$plan_file")

## Project Context
- Language: ${project_lang}
- Test command: ${TEST_CMD:-not configured}
- Task type: ${TASK_TYPE:-feature}
${memory_context:+
## Historical Context (from memory)
${memory_context}
}${arch_context:+
## Architecture Model (from previous designs)
${arch_context}
}${design_antipatterns}
## Required Output — Architecture Decision Record

Produce this EXACT format:

# Design: ${GOAL}

## Context
[What problem we're solving, constraints from the codebase]

## Decision
[The chosen approach — be specific about patterns, data flow, error handling]

## Alternatives Considered
1. [Alternative A] — Pros: ... / Cons: ...
2. [Alternative B] — Pros: ... / Cons: ...

## Implementation Plan
- Files to create: [list with full paths]
- Files to modify: [list with full paths]
- Dependencies: [new deps if any]
- Risk areas: [fragile code, performance concerns]

## Validation Criteria
- [ ] [How we'll know the design is correct — testable criteria]
- [ ] [Additional validation items]

Be concrete and specific. Reference actual file paths in the codebase. Consider edge cases and failure modes."

    local design_model
    design_model=$(jq -r --arg id "design" '(.stages[] | select(.id == $id) | .config.model) // .defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -n "$MODEL" ]] && design_model="$MODEL"
    [[ -z "$design_model" || "$design_model" == "null" ]] && design_model="opus"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        design_model="$CLAUDE_MODEL"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-design.log"
    claude --print --model "$design_model" --max-turns 25 \
        "$design_prompt" < /dev/null > "$design_file" 2>"$_token_log" || true
    parse_claude_tokens "$_token_log"

    if [[ ! -s "$design_file" ]]; then
        error "Design generation failed"
        return 1
    fi

    local line_count
    line_count=$(wc -l < "$design_file" | xargs)
    info "Design saved: ${DIM}$design_file${RESET} (${line_count} lines)"

    # Extract file lists for build stage awareness
    local files_to_create files_to_modify
    files_to_create=$(sed -n '/Files to create/,/^-\|^#\|^$/p' "$design_file" 2>/dev/null | grep -E '^\s*-' | head -20 || true)
    files_to_modify=$(sed -n '/Files to modify/,/^-\|^#\|^$/p' "$design_file" 2>/dev/null | grep -E '^\s*-' | head -20 || true)

    if [[ -n "$files_to_create" || -n "$files_to_modify" ]]; then
        info "Design scope: ${DIM}$(echo "$files_to_create $files_to_modify" | grep -c '^\s*-' || echo 0) file(s)${RESET}"
    fi

    # Post design to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local design_summary
        design_summary=$(head -60 "$design_file")
        gh_comment_issue "$ISSUE_NUMBER" "## 📐 Architecture Decision Record

<details>
<summary>Click to expand ADR (${line_count} lines)</summary>

${design_summary}

</details>

---
_Generated by \`shipwright pipeline\` design stage at $(now_iso)_"
    fi

    # Push design to wiki
    gh_wiki_page "Pipeline-Design-${ISSUE_NUMBER:-inline}" "$(<"$design_file")"

    log_stage "design" "Generated design.md (${line_count} lines)"
}

stage_build() {
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local design_file="$ARTIFACTS_DIR/design.md"
    local dod_file="$ARTIFACTS_DIR/dod.md"
    local loop_args=()

    # Memory integration — inject context if memory system available
    local memory_context=""
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local mem_dir="${HOME}/.shipwright/memory"
        memory_context=$(intelligence_search_memory "build stage for: ${GOAL:-}" "$mem_dir" 5 2>/dev/null) || true
    fi
    if [[ -z "$memory_context" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/sw-memory.sh" inject "build" 2>/dev/null) || true
    fi

    # Build enriched goal with compact context (avoids prompt bloat)
    local enriched_goal
    enriched_goal=$(_pipeline_compact_goal "$GOAL" "$plan_file" "$design_file")

    # Inject memory context
    if [[ -n "$memory_context" ]]; then
        enriched_goal="${enriched_goal}

Historical context (lessons from previous pipelines):
${memory_context}"
    fi

    # Add task list context
    if [[ -s "$TASKS_FILE" ]]; then
        enriched_goal="${enriched_goal}

Task tracking (check off items as you complete them):
$(cat "$TASKS_FILE")"
    fi

    # Inject file hotspots from GitHub intelligence
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_file_change_frequency &>/dev/null 2>&1; then
        local build_hotspots
        build_hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
        if [[ -n "$build_hotspots" ]]; then
            enriched_goal="${enriched_goal}

File hotspots (most frequently changed — review these carefully):
${build_hotspots}"
        fi
    fi

    # Inject security alerts context
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_security_alerts &>/dev/null 2>&1; then
        local build_alerts
        build_alerts=$(gh_security_alerts 2>/dev/null | head -3 || true)
        if [[ -n "$build_alerts" ]]; then
            enriched_goal="${enriched_goal}

Active security alerts (do not introduce new vulnerabilities):
${build_alerts}"
        fi
    fi

    # Inject coverage baseline
    local repo_hash_build
    repo_hash_build=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local coverage_file_build="${HOME}/.shipwright/baselines/${repo_hash_build}/coverage.json"
    if [[ -f "$coverage_file_build" ]]; then
        local coverage_baseline
        coverage_baseline=$(jq -r '.coverage_percent // empty' "$coverage_file_build" 2>/dev/null || true)
        if [[ -n "$coverage_baseline" ]]; then
            enriched_goal="${enriched_goal}

Coverage baseline: ${coverage_baseline}% — do not decrease coverage."
        fi
    fi

    loop_args+=("$enriched_goal")

    # Build loop args from pipeline config + CLI overrides
    CURRENT_STAGE_ID="build"

    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect if still empty
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    local max_iter
    max_iter=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.max_iterations) // 20' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_iter" || "$max_iter" == "null" ]] && max_iter=20
    # CLI --max-iterations override (from CI strategy engine)
    [[ -n "${MAX_ITERATIONS_OVERRIDE:-}" ]] && max_iter="$MAX_ITERATIONS_OVERRIDE"

    local agents="${AGENTS}"
    if [[ -z "$agents" ]]; then
        agents=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.agents) // .defaults.agents // 1' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$agents" || "$agents" == "null" ]] && agents=1
    fi

    # Intelligence: suggest parallelism if design indicates independent work
    if [[ "${agents:-1}" -le 1 ]] && [[ -s "$ARTIFACTS_DIR/design.md" ]]; then
        local design_lower
        design_lower=$(tr '[:upper:]' '[:lower:]' < "$ARTIFACTS_DIR/design.md" 2>/dev/null || true)
        if echo "$design_lower" | grep -qE 'independent (files|modules|components|services)|separate (modules|packages|directories)|parallel|no shared state'; then
            info "Design mentions independent modules — consider --agents 2 for parallelism"
            emit_event "build.parallelism_suggested" "issue=${ISSUE_NUMBER:-0}" "current_agents=$agents"
        fi
    fi

    local audit
    audit=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.audit) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    local quality
    quality=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.quality_gates) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    local build_model="${MODEL}"
    if [[ -z "$build_model" ]]; then
        build_model=$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$build_model" || "$build_model" == "null" ]] && build_model="opus"
    fi
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        build_model="$CLAUDE_MODEL"
    fi

    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && loop_args+=(--test-cmd "$test_cmd")
    loop_args+=(--max-iterations "$max_iter")
    loop_args+=(--model "$build_model")
    [[ "$agents" -gt 1 ]] 2>/dev/null && loop_args+=(--agents "$agents")

    # Quality gates: always enabled in CI, otherwise from template config
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        loop_args+=(--audit --audit-agent --quality-gates)
    else
        [[ "$audit" == "true" ]] && loop_args+=(--audit --audit-agent)
        [[ "$quality" == "true" ]] && loop_args+=(--quality-gates)
    fi

    # Session restart capability
    [[ -n "${MAX_RESTARTS_OVERRIDE:-}" ]] && loop_args+=(--max-restarts "$MAX_RESTARTS_OVERRIDE")
    # Fast test mode
    [[ -n "${FAST_TEST_CMD_OVERRIDE:-}" ]] && loop_args+=(--fast-test-cmd "$FAST_TEST_CMD_OVERRIDE")

    # Definition of Done: use plan-extracted DoD if available
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    # Skip permissions in CI (no interactive terminal)
    [[ "${CI_MODE:-false}" == "true" ]] && loop_args+=(--skip-permissions)

    info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

    # Post build start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
    export PIPELINE_JOB_ID="${PIPELINE_NAME:-pipeline-$$}"
    sw loop "${loop_args[@]}" < /dev/null 2>"$_token_log" || {
        local _loop_exit=$?
        parse_claude_tokens "$_token_log"

        # Detect context exhaustion from progress file
        local _progress_file=".claude/loop-logs/progress.md"
        if [[ -f "$_progress_file" ]]; then
            local _prog_tests
            _prog_tests=$(grep -oE 'Tests passing: (true|false)' "$_progress_file" 2>/dev/null | awk '{print $NF}' || echo "unknown")
            if [[ "$_prog_tests" != "true" ]]; then
                warn "Build loop exhausted with failing tests (context exhaustion)"
                emit_event "pipeline.context_exhaustion" "issue=${ISSUE_NUMBER:-0}" "stage=build"
                # Write flag for daemon retry logic
                echo "context_exhaustion" > "$ARTIFACTS_DIR/failure-reason.txt" 2>/dev/null || true
            fi
        fi

        error "Build loop failed"
        return 1
    }
    parse_claude_tokens "$_token_log"

    # Count commits made during build
    local commit_count
    commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

    # Commit quality evaluation when intelligence is enabled
    if type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null && [[ "${commit_count:-0}" -gt 0 ]]; then
        local commit_msgs
        commit_msgs=$(git log --format="%s" "${BASE_BRANCH}..HEAD" 2>/dev/null | head -20)
        local quality_score
        quality_score=$(claude --print --output-format text -p "Rate the quality of these git commit messages on a scale of 0-100. Consider: focus (one thing per commit), clarity (describes the why), atomicity (small logical units). Reply with ONLY a number 0-100.

Commit messages:
${commit_msgs}" --model haiku < /dev/null 2>/dev/null || true)
        quality_score=$(echo "$quality_score" | grep -oE '^[0-9]+' | head -1 || true)
        if [[ -n "$quality_score" ]]; then
            emit_event "build.commit_quality" \
                "issue=${ISSUE_NUMBER:-0}" \
                "score=$quality_score" \
                "commit_count=$commit_count"
            if [[ "$quality_score" -lt 40 ]] 2>/dev/null; then
                warn "Commit message quality low (score: ${quality_score}/100)"
            else
                info "Commit quality score: ${quality_score}/100"
            fi
        fi
    fi

    log_stage "build" "Build loop completed ($commit_count commits)"
}

stage_test() {
    CURRENT_STAGE_ID="test"
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.test_cmd) // .defaults.test_cmd // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$test_cmd" || "$test_cmd" == "null" ]] && test_cmd=""
    fi
    # Auto-detect
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi
    if [[ -z "$test_cmd" ]]; then
        warn "No test command found — skipping test stage"
        return 0
    fi

    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    local test_log="$ARTIFACTS_DIR/test-results.log"

    info "Running tests: ${DIM}$test_cmd${RESET}"
    local test_exit=0
    bash -c "$test_cmd" > "$test_log" 2>&1 || test_exit=$?

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"
    else
        error "Tests failed (exit code: $test_exit)"
        # Extract most relevant error section (assertion failures, stack traces)
        local relevant_output=""
        relevant_output=$(grep -A5 -E 'FAIL|AssertionError|Expected.*but.*got|Error:|panic:|assert' "$test_log" 2>/dev/null | tail -40 || true)
        if [[ -z "$relevant_output" ]]; then
            relevant_output=$(tail -40 "$test_log")
        fi
        echo "$relevant_output"

        # Post failure to GitHub with more context
        if [[ -n "$ISSUE_NUMBER" ]]; then
            local log_lines
            log_lines=$(wc -l < "$test_log" 2>/dev/null || echo "0")
            local log_excerpt
            if [[ "$log_lines" -lt 60 ]]; then
                log_excerpt="$(cat "$test_log" 2>/dev/null || true)"
            else
                log_excerpt="$(head -20 "$test_log" 2>/dev/null || true)
... (${log_lines} lines total, showing head + tail) ...
$(tail -30 "$test_log" 2>/dev/null || true)"
            fi
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Tests failed** (exit code: $test_exit, ${log_lines} lines)
\`\`\`
${log_excerpt}
\`\`\`"
        fi
        return 1
    fi

    # Coverage check — only enforce when coverage data is actually detected
    local coverage=""
    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null; then
        coverage=$(parse_coverage_from_output "$test_log")
        if [[ -z "$coverage" ]]; then
            # No coverage data found — skip enforcement (project may not have coverage tooling)
            info "No coverage data detected — skipping coverage check (min: ${coverage_min}%)"
        elif awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
            warn "Coverage ${coverage}% below minimum ${coverage_min}%"
            return 1
        else
            info "Coverage: ${coverage}% (min: ${coverage_min}%)"
        fi
    fi

    # Post test results to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local test_summary
        test_summary=$(tail -10 "$test_log")
        local cov_line=""
        [[ -n "$coverage" ]] && cov_line="
**Coverage:** ${coverage}%"
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Tests passed**${cov_line}
<details>
<summary>Test output</summary>

\`\`\`
${test_summary}
\`\`\`
</details>"
    fi

    # Write coverage summary for pre-deploy gate
    local _cov_pct=0
    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]]; then
        _cov_pct=$(grep -oE '[0-9]+%' "$ARTIFACTS_DIR/test-results.log" 2>/dev/null | head -1 | tr -d '%' || true)
        _cov_pct="${_cov_pct:-0}"
    fi
    local _cov_tmp
    _cov_tmp=$(mktemp "${ARTIFACTS_DIR}/test-coverage.json.tmp.XXXXXX")
    printf '{"coverage_pct":%d}' "${_cov_pct:-0}" > "$_cov_tmp" && mv "$_cov_tmp" "$ARTIFACTS_DIR/test-coverage.json" || rm -f "$_cov_tmp"

    log_stage "test" "Tests passed${coverage:+ (coverage: ${coverage}%)}"
}

stage_review() {
    CURRENT_STAGE_ID="review"
    local diff_file="$ARTIFACTS_DIR/review-diff.patch"
    local review_file="$ARTIFACTS_DIR/review.md"

    git diff "${BASE_BRANCH}...${GIT_BRANCH}" > "$diff_file" 2>/dev/null || \
        git diff HEAD~5 > "$diff_file" 2>/dev/null || true

    if [[ ! -s "$diff_file" ]]; then
        warn "No diff found — skipping review"
        return 0
    fi

    if ! command -v claude &>/dev/null; then
        warn "Claude CLI not found — skipping AI review"
        return 0
    fi

    local diff_stats
    diff_stats=$(git diff --stat "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null | tail -1 || echo "")
    info "Running AI code review... ${DIM}($diff_stats)${RESET}"

    # Semantic risk scoring when intelligence is enabled
    if type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null; then
        local diff_files
        diff_files=$(git diff --name-only "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null || true)
        local risk_score="low"
        # Fast heuristic: flag high-risk file patterns
        if echo "$diff_files" | grep -qiE 'migration|schema|auth|crypto|security|password|token|secret|\.env'; then
            risk_score="high"
        elif echo "$diff_files" | grep -qiE 'api|route|controller|middleware|hook'; then
            risk_score="medium"
        fi
        emit_event "review.risk_assessed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "risk=$risk_score" \
            "files_changed=$(echo "$diff_files" | wc -l | xargs)"
        if [[ "$risk_score" == "high" ]]; then
            warn "High-risk changes detected (DB schema, auth, crypto, or secrets)"
        fi
    fi

    local review_model="${MODEL:-opus}"
    # Intelligence model routing (when no explicit CLI --model override)
    if [[ -z "$MODEL" && -n "${CLAUDE_MODEL:-}" ]]; then
        review_model="$CLAUDE_MODEL"
    fi

    # Build review prompt with project context
    local review_prompt="You are a senior code reviewer. Review this git diff thoroughly.

For each issue found, use this format:
- **[SEVERITY]** file:line — description

Severity levels: Critical, Bug, Security, Warning, Suggestion

Focus on:
1. Logic bugs and edge cases
2. Security vulnerabilities (injection, XSS, auth bypass, etc.)
3. Error handling gaps
4. Performance issues
5. Missing validation
6. Project convention violations (see conventions below)

Be specific. Reference exact file paths and line numbers. Only flag genuine issues.
If no issues are found, write: \"Review clean — no issues found.\"
"

    # Inject previous review findings and anti-patterns from memory
    if type intelligence_search_memory &>/dev/null 2>&1; then
        local review_memory
        review_memory=$(intelligence_search_memory "code review findings anti-patterns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
        if [[ -n "$review_memory" ]]; then
            review_prompt+="
## Known Issues from Previous Reviews
These anti-patterns and issues have been found in past reviews of this codebase. Flag them if they recur:
${review_memory}
"
        fi
    fi

    # Inject project conventions if CLAUDE.md exists
    local claudemd="$PROJECT_ROOT/.claude/CLAUDE.md"
    if [[ -f "$claudemd" ]]; then
        local conventions
        conventions=$(grep -A2 'Common Pitfalls\|Shell Standards\|Bash 3.2' "$claudemd" 2>/dev/null | head -20 || true)
        if [[ -n "$conventions" ]]; then
            review_prompt+="
## Project Conventions
${conventions}
"
        fi
    fi

    # Inject CODEOWNERS focus areas for review
    if [[ "${NO_GITHUB:-}" != "true" ]] && type gh_codeowners &>/dev/null 2>&1; then
        local review_owners
        review_owners=$(gh_codeowners 2>/dev/null | head -10 || true)
        if [[ -n "$review_owners" ]]; then
            review_prompt+="
## Code Owners (focus areas)
${review_owners}
"
        fi
    fi

    # Inject Definition of Done if present
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"
    if [[ -f "$dod_file" ]]; then
        review_prompt+="
## Definition of Done (verify these)
$(cat "$dod_file")
"
    fi

    review_prompt+="
## Diff to Review
$(cat "$diff_file")"

    # Build claude args — add --dangerously-skip-permissions in CI
    local review_args=(--print --model "$review_model" --max-turns 25)
    if [[ "${CI_MODE:-false}" == "true" ]]; then
        review_args+=(--dangerously-skip-permissions)
    fi

    claude "${review_args[@]}" "$review_prompt" < /dev/null > "$review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-review.log" || true
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-review.log"

    if [[ ! -s "$review_file" ]]; then
        warn "Review produced no output — check ${ARTIFACTS_DIR}/.claude-tokens-review.log for errors"
        return 0
    fi

    # Extract severity counts — try JSON structure first, then grep fallback
    local critical_count=0 bug_count=0 warning_count=0

    # Check if review output is structured JSON (e.g. from structured review tools)
    local json_parsed=false
    if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
        local j_critical j_bug j_warning
        j_critical=$(jq -r '.issues | map(select(.severity == "Critical")) | length' "$review_file" 2>/dev/null || echo "")
        if [[ -n "$j_critical" && "$j_critical" != "null" ]]; then
            critical_count="$j_critical"
            bug_count=$(jq -r '.issues | map(select(.severity == "Bug" or .severity == "Security")) | length' "$review_file" 2>/dev/null || echo "0")
            warning_count=$(jq -r '.issues | map(select(.severity == "Warning" or .severity == "Suggestion")) | length' "$review_file" 2>/dev/null || echo "0")
            json_parsed=true
        fi
    fi

    # Grep fallback for markdown-formatted review output
    if [[ "$json_parsed" != "true" ]]; then
        critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$review_file" 2>/dev/null || true)
        critical_count="${critical_count:-0}"
        bug_count=$(grep -ciE '\*\*\[?(Bug|Security)\]?\*\*' "$review_file" 2>/dev/null || true)
        bug_count="${bug_count:-0}"
        warning_count=$(grep -ciE '\*\*\[?(Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
        warning_count="${warning_count:-0}"
    fi
    local total_issues=$((critical_count + bug_count + warning_count))

    if [[ "$critical_count" -gt 0 ]]; then
        error "Review found ${BOLD}$critical_count critical${RESET} issue(s) — see $review_file"
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Review found $bug_count bug/security issue(s) — see ${DIM}$review_file${RESET}"
    elif [[ "$total_issues" -gt 0 ]]; then
        info "Review found $total_issues suggestion(s)"
    else
        success "Review clean"
    fi

    # ── Review Blocking Gate ──
    # Block pipeline on critical/security issues unless compound_quality handles them
    local security_count
    security_count=$(grep -ciE '\*\*\[?Security\]?\*\*' "$review_file" 2>/dev/null || true)
    security_count="${security_count:-0}"

    local blocking_issues=$((critical_count + security_count))

    if [[ "$blocking_issues" -gt 0 ]]; then
        # Check if compound_quality stage is enabled — if so, let it handle issues
        local compound_enabled="false"
        if [[ -n "${PIPELINE_CONFIG:-}" && -f "${PIPELINE_CONFIG:-/dev/null}" ]]; then
            compound_enabled=$(jq -r '.stages[] | select(.id == "compound_quality") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null) || true
            [[ -z "$compound_enabled" || "$compound_enabled" == "null" ]] && compound_enabled="false"
        fi

        # Check if this is a fast template (don't block fast pipelines)
        local is_fast="false"
        if [[ "${PIPELINE_NAME:-}" == "fast" || "${PIPELINE_NAME:-}" == "hotfix" ]]; then
            is_fast="true"
        fi

        if [[ "$compound_enabled" == "true" ]]; then
            info "Review found ${blocking_issues} critical/security issue(s) — compound_quality stage will handle"
        elif [[ "$is_fast" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — fast template, not blocking"
        elif [[ "${SKIP_GATES:-false}" == "true" ]]; then
            warn "Review found ${blocking_issues} critical/security issue(s) — skip-gates mode, not blocking"
        else
            error "Review found ${BOLD}${blocking_issues} critical/security issue(s)${RESET} — blocking pipeline"
            emit_event "review.blocked" \
                "issue=${ISSUE_NUMBER:-0}" \
                "critical=${critical_count}" \
                "security=${security_count}"

            # Save blocking issues for self-healing context
            grep -iE '\*\*\[?(Critical|Security)\]?\*\*' "$review_file" > "$ARTIFACTS_DIR/review-blockers.md" 2>/dev/null || true

            # Post review to GitHub before failing
            if [[ -n "$ISSUE_NUMBER" ]]; then
                local review_summary
                review_summary=$(head -40 "$review_file")
                gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review — ❌ Blocked

**Stats:** $diff_stats
**Blocking issues:** ${blocking_issues} (${critical_count} critical, ${security_count} security)

<details>
<summary>Review details</summary>

${review_summary}

</details>

_Pipeline will attempt self-healing rebuild._"
            fi

            log_stage "review" "BLOCKED: $blocking_issues critical/security issues found"
            return 1
        fi
    fi

    # Post review to GitHub issue
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local review_summary
        review_summary=$(head -40 "$review_file")
        gh_comment_issue "$ISSUE_NUMBER" "## 🔍 Code Review

**Stats:** $diff_stats
**Issues found:** $total_issues (${critical_count} critical, ${bug_count} bugs, ${warning_count} suggestions)

<details>
<summary>Review details</summary>

${review_summary}

</details>"
    fi

    log_stage "review" "AI review complete ($total_issues issues: $critical_count critical, $bug_count bugs, $warning_count suggestions)"
}

stage_pr() {
    CURRENT_STAGE_ID="pr"
    local plan_file="$ARTIFACTS_DIR/plan.md"
    local test_log="$ARTIFACTS_DIR/test-results.log"
    local review_file="$ARTIFACTS_DIR/review.md"

    # ── PR Hygiene Checks (informational) ──
    local hygiene_commit_count
    hygiene_commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)
    hygiene_commit_count="${hygiene_commit_count:-0}"

    if [[ "$hygiene_commit_count" -gt 20 ]]; then
        warn "PR has ${hygiene_commit_count} commits — consider squashing before merge"
    fi

    # Check for WIP/fixup/squash commits (expanded patterns)
    local wip_commits
    wip_commits=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | grep -ciE '^[0-9a-f]+ (WIP|fixup!|squash!|TODO|HACK|TEMP|BROKEN|wip[:-]|temp[:-]|broken[:-]|do not merge)' || true)
    wip_commits="${wip_commits:-0}"
    if [[ "$wip_commits" -gt 0 ]]; then
        warn "Branch has ${wip_commits} WIP/fixup/squash/temp commit(s) — consider cleaning up"
    fi

    # ── PR Quality Gate: reject PRs with no real code changes ──
    local real_files
    real_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -v '^\.claude/' | grep -v '^\.github/' || true)
    if [[ -z "$real_files" ]]; then
        error "No real code changes detected — only pipeline artifacts (.claude/ logs)."
        error "The build agent did not produce meaningful changes. Skipping PR creation."
        emit_event "pr.rejected" "issue=${ISSUE_NUMBER:-0}" "reason=no_real_changes"
        # Mark issue so auto-retry knows not to retry empty builds
        if [[ -n "${ISSUE_NUMBER:-}" && "${ISSUE_NUMBER:-0}" != "0" ]]; then
            gh issue comment "$ISSUE_NUMBER" --body "<!-- SHIPWRIGHT-NO-CHANGES: true -->" 2>/dev/null || true
        fi
        return 1
    fi
    local real_file_count
    real_file_count=$(echo "$real_files" | wc -l | xargs)
    info "PR quality gate: ${real_file_count} real file(s) changed"

    # Commit any uncommitted changes left by the build agent
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        info "Committing remaining uncommitted changes..."
        git add -A 2>/dev/null || true
        git commit -m "chore: pipeline cleanup — commit remaining build changes" --no-verify 2>/dev/null || true
    fi

    # Auto-rebase onto latest base branch before PR
    auto_rebase || {
        warn "Rebase/merge failed — pushing as-is"
    }

    # Push branch
    info "Pushing branch: $GIT_BRANCH"
    git push -u origin "$GIT_BRANCH" --force-with-lease 2>/dev/null || {
        # Retry with regular push if force-with-lease fails (first push)
        git push -u origin "$GIT_BRANCH" 2>/dev/null || {
            error "Failed to push branch"
            return 1
        }
    }

    # ── Developer Simulation (pre-PR review) ──
    local simulation_summary=""
    if type simulation_review &>/dev/null 2>&1; then
        local sim_enabled
        sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        # Also check daemon-config
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$sim_enabled" == "true" ]]; then
            info "Running developer simulation review..."
            local diff_for_sim
            diff_for_sim=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
            if [[ -n "$diff_for_sim" ]]; then
                local sim_result
                sim_result=$(simulation_review "$diff_for_sim" "${GOAL:-}" 2>/dev/null || echo "")
                if [[ -n "$sim_result" && "$sim_result" != *'"error"'* ]]; then
                    echo "$sim_result" > "$ARTIFACTS_DIR/simulation-review.json"
                    local sim_count
                    sim_count=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                    simulation_summary="**Developer simulation:** ${sim_count} reviewer concerns pre-addressed"
                    success "Simulation complete: ${sim_count} concerns found and addressed"
                    emit_event "simulation.complete" "issue=${ISSUE_NUMBER:-0}" "concerns=${sim_count}"
                else
                    info "Simulation returned no actionable concerns"
                fi
            fi
        fi
    fi

    # ── Architecture Validation (pre-PR check) ──
    local arch_summary=""
    if type architecture_validate_changes &>/dev/null 2>&1; then
        local arch_enabled
        arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
        local daemon_cfg=".claude/daemon-config.json"
        if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$arch_enabled" == "true" ]]; then
            info "Validating architecture..."
            local diff_for_arch
            diff_for_arch=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
            if [[ -n "$diff_for_arch" ]]; then
                local arch_result
                arch_result=$(architecture_validate_changes "$diff_for_arch" "" 2>/dev/null || echo "")
                if [[ -n "$arch_result" && "$arch_result" != *'"error"'* ]]; then
                    echo "$arch_result" > "$ARTIFACTS_DIR/architecture-validation.json"
                    local violation_count
                    violation_count=$(echo "$arch_result" | jq '[.violations[]? | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                    arch_summary="**Architecture validation:** ${violation_count} violations"
                    if [[ "$violation_count" -gt 0 ]]; then
                        warn "Architecture: ${violation_count} high/critical violations found"
                    else
                        success "Architecture validation passed"
                    fi
                    emit_event "architecture.validated" "issue=${ISSUE_NUMBER:-0}" "violations=${violation_count}"
                else
                    info "Architecture validation returned no results"
                fi
            fi
        fi
    fi

    # Build PR title — prefer GOAL over plan file first line
    # (plan file first line often contains Claude analysis text, not a clean title)
    local pr_title=""
    if [[ -n "${GOAL:-}" ]]; then
        pr_title=$(echo "$GOAL" | cut -c1-70)
    fi
    if [[ -z "$pr_title" ]] && [[ -s "$plan_file" ]]; then
        pr_title=$(head -1 "$plan_file" 2>/dev/null | sed 's/^#* *//' | cut -c1-70)
    fi
    [[ -z "$pr_title" ]] && pr_title="Pipeline changes for issue ${ISSUE_NUMBER:-unknown}"

    # Build comprehensive PR body
    local plan_summary=""
    if [[ -s "$plan_file" ]]; then
        plan_summary=$(head -20 "$plan_file" 2>/dev/null | tail -15)
    fi

    local test_summary=""
    if [[ -s "$test_log" ]]; then
        test_summary=$(tail -10 "$test_log")
    fi

    local review_summary=""
    if [[ -s "$review_file" ]]; then
        local total_issues=0
        # Try JSON structured output first
        if head -1 "$review_file" 2>/dev/null | grep -q '^{' 2>/dev/null; then
            total_issues=$(jq -r '.issues | length' "$review_file" 2>/dev/null || echo "0")
        fi
        # Grep fallback for markdown
        if [[ "${total_issues:-0}" -eq 0 ]]; then
            total_issues=$(grep -ciE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
            total_issues="${total_issues:-0}"
        fi
        review_summary="**Code review:** $total_issues issues found"
    fi

    local closes_line=""
    [[ -n "${GITHUB_ISSUE:-}" ]] && closes_line="Closes ${GITHUB_ISSUE}"

    local diff_stats
    diff_stats=$(git diff --stat "${BASE_BRANCH}...${GIT_BRANCH}" 2>/dev/null | tail -1 || echo "")

    local commit_count
    commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)

    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    local pr_body
    pr_body="$(cat <<EOF
## Summary
${plan_summary:-$GOAL}

## Changes
${diff_stats}
${commit_count} commit(s) via \`shipwright pipeline\` (${PIPELINE_NAME})

## Test Results
\`\`\`
${test_summary:-No test output}
\`\`\`

${review_summary}
${simulation_summary}
${arch_summary}

${closes_line}

---

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Duration | ${total_dur:-—} |
| Model | ${MODEL:-opus} |
| Agents | ${AGENTS:-1} |

Generated by \`shipwright pipeline\`
EOF
)"

    # Build gh pr create args
    local pr_args=(--title "$pr_title" --body "$pr_body" --base "$BASE_BRANCH")

    # Propagate labels from issue + CLI
    local all_labels="${LABELS}"
    if [[ -n "$ISSUE_LABELS" ]]; then
        if [[ -n "$all_labels" ]]; then
            all_labels="${all_labels},${ISSUE_LABELS}"
        else
            all_labels="$ISSUE_LABELS"
        fi
    fi
    if [[ -n "$all_labels" ]]; then
        pr_args+=(--label "$all_labels")
    fi

    # Auto-detect or use provided reviewers
    local reviewers="${REVIEWERS}"
    if [[ -z "$reviewers" ]]; then
        reviewers=$(detect_reviewers)
    fi
    if [[ -n "$reviewers" ]]; then
        pr_args+=(--reviewer "$reviewers")
        info "Reviewers: ${DIM}$reviewers${RESET}"
    fi

    # Propagate milestone
    if [[ -n "$ISSUE_MILESTONE" ]]; then
        pr_args+=(--milestone "$ISSUE_MILESTONE")
        info "Milestone: ${DIM}$ISSUE_MILESTONE${RESET}"
    fi

    # Check for existing open PR on this branch to avoid duplicates (issue #12)
    local pr_url=""
    local existing_pr
    existing_pr=$(gh pr list --head "$GIT_BRANCH" --state open --json number,url --jq '.[0]' 2>/dev/null || echo "")
    if [[ -n "$existing_pr" && "$existing_pr" != "null" ]]; then
        local existing_pr_number existing_pr_url
        existing_pr_number=$(echo "$existing_pr" | jq -r '.number' 2>/dev/null || echo "")
        existing_pr_url=$(echo "$existing_pr" | jq -r '.url' 2>/dev/null || echo "")
        info "Updating existing PR #$existing_pr_number instead of creating duplicate"
        gh pr edit "$existing_pr_number" --title "$pr_title" --body "$pr_body" 2>/dev/null || true
        pr_url="$existing_pr_url"
    else
        info "Creating PR..."
        local pr_stderr pr_exit=0
        pr_url=$(gh pr create "${pr_args[@]}" 2>/tmp/shipwright-pr-stderr.txt) || pr_exit=$?
        pr_stderr=$(cat /tmp/shipwright-pr-stderr.txt 2>/dev/null || true)
        rm -f /tmp/shipwright-pr-stderr.txt

        # gh pr create may return non-zero for reviewer issues but still create the PR
        if [[ "$pr_exit" -ne 0 ]]; then
            if [[ "$pr_url" == *"github.com"* ]]; then
                # PR was created but something non-fatal failed (e.g., reviewer not found)
                warn "PR created with warnings: ${pr_stderr:-unknown}"
            else
                error "PR creation failed: ${pr_stderr:-$pr_url}"
                return 1
            fi
        fi
    fi

    success "PR created: ${BOLD}$pr_url${RESET}"
    echo "$pr_url" > "$ARTIFACTS_DIR/pr-url.txt"

    # Extract PR number
    PR_NUMBER=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)

    # ── Intelligent Reviewer Selection (GraphQL-enhanced) ──
    if [[ "${NO_GITHUB:-false}" != "true" && -n "$PR_NUMBER" && -z "$reviewers" ]]; then
        local reviewer_assigned=false

        # Try CODEOWNERS-based routing via GraphQL API
        if type gh_codeowners &>/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local codeowners_json
            codeowners_json=$(gh_codeowners "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            if [[ "$codeowners_json" != "[]" && -n "$codeowners_json" ]]; then
                local changed_files
                changed_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$changed_files" ]]; then
                    local co_reviewers
                    co_reviewers=$(echo "$codeowners_json" | jq -r '.[].owners[]' 2>/dev/null | sort -u | head -3 || true)
                    if [[ -n "$co_reviewers" ]]; then
                        local rev
                        while IFS= read -r rev; do
                            rev="${rev#@}"
                            [[ -n "$rev" ]] && gh pr edit "$PR_NUMBER" --add-reviewer "$rev" 2>/dev/null || true
                        done <<< "$co_reviewers"
                        info "Requested review from CODEOWNERS: $(echo "$co_reviewers" | tr '\n' ',' | sed 's/,$//')"
                        reviewer_assigned=true
                    fi
                fi
            fi
        fi

        # Fallback: contributor-based routing via GraphQL API
        if [[ "$reviewer_assigned" != "true" ]] && type gh_contributors &>/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local contributors_json
            contributors_json=$(gh_contributors "$REPO_OWNER" "$REPO_NAME" 2>/dev/null || echo "[]")
            local top_contributor
            top_contributor=$(echo "$contributors_json" | jq -r '.[0].login // ""' 2>/dev/null || echo "")
            local current_user
            current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
            if [[ -n "$top_contributor" && "$top_contributor" != "$current_user" ]]; then
                gh pr edit "$PR_NUMBER" --add-reviewer "$top_contributor" 2>/dev/null || true
                info "Requested review from top contributor: $top_contributor"
                reviewer_assigned=true
            fi
        fi

        # Final fallback: auto-approve if no reviewers assigned
        if [[ "$reviewer_assigned" != "true" ]]; then
            gh pr review "$PR_NUMBER" --approve 2>/dev/null || warn "Could not auto-approve PR"
        fi
    fi

    # Update issue with PR link
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_comment_issue "$ISSUE_NUMBER" "🎉 **PR created:** ${pr_url}

Pipeline duration so far: ${total_dur:-unknown}"

        # Notify tracker of review/PR creation
        "$SCRIPT_DIR/sw-tracker.sh" notify "review" "$ISSUE_NUMBER" "$pr_url" 2>/dev/null || true
    fi

    # Wait for CI if configured
    local wait_ci
    wait_ci=$(jq -r --arg id "pr" '(.stages[] | select(.id == $id) | .config.wait_ci) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ "$wait_ci" == "true" ]]; then
        info "Waiting for CI checks..."
        gh pr checks --watch 2>/dev/null || warn "CI checks did not all pass"
    fi

    log_stage "pr" "PR created: $pr_url (${reviewers:+reviewers: $reviewers})"
}

stage_merge() {
    CURRENT_STAGE_ID="merge"

    if [[ "$NO_GITHUB" == "true" ]]; then
        info "Merge stage skipped (--no-github)"
        return 0
    fi

    # ── Branch Protection Check ──
    if type gh_branch_protection &>/dev/null 2>&1 && [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
        local protection_json
        protection_json=$(gh_branch_protection "$REPO_OWNER" "$REPO_NAME" "${BASE_BRANCH:-main}" 2>/dev/null || echo '{"protected": false}')
        local is_protected
        is_protected=$(echo "$protection_json" | jq -r '.protected // false' 2>/dev/null || echo "false")
        if [[ "$is_protected" == "true" ]]; then
            local required_reviews
            required_reviews=$(echo "$protection_json" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0' 2>/dev/null || echo "0")
            local required_checks
            required_checks=$(echo "$protection_json" | jq -r '[.required_status_checks.contexts // [] | .[]] | length' 2>/dev/null || echo "0")

            info "Branch protection: ${required_reviews} required review(s), ${required_checks} required check(s)"

            if [[ "$required_reviews" -gt 0 ]]; then
                # Check if PR has enough approvals
                local prot_pr_number
                prot_pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")
                if [[ -n "$prot_pr_number" ]]; then
                    local approvals
                    approvals=$(gh pr view "$prot_pr_number" --json reviews --jq '[.reviews[] | select(.state == "APPROVED")] | length' 2>/dev/null || echo "0")
                    if [[ "$approvals" -lt "$required_reviews" ]]; then
                        warn "PR has $approvals approval(s), needs $required_reviews — skipping auto-merge"
                        info "PR is ready for manual merge after required reviews"
                        emit_event "merge.blocked" "issue=${ISSUE_NUMBER:-0}" "reason=insufficient_reviews" "have=$approvals" "need=$required_reviews"
                        return 0
                    fi
                fi
            fi
        fi
    fi

    local merge_method wait_ci_timeout auto_delete_branch auto_merge auto_approve merge_strategy
    merge_method=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_method) // "squash"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_method" || "$merge_method" == "null" ]] && merge_method="squash"
    wait_ci_timeout=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.wait_ci_timeout_s) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=0

    # Adaptive CI timeout: 90th percentile of historical times × 1.5 safety margin
    if [[ "$wait_ci_timeout" -eq 0 ]] 2>/dev/null; then
        local repo_hash_ci
        repo_hash_ci=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_file="${HOME}/.shipwright/baselines/${repo_hash_ci}/ci-times.json"
        if [[ -f "$ci_times_file" ]]; then
            local p90_time
            p90_time=$(jq '
                .times | sort |
                (length * 0.9 | floor) as $idx |
                .[$idx] // 600
            ' "$ci_times_file" 2>/dev/null || echo "0")
            if [[ -n "$p90_time" ]] && awk -v t="$p90_time" 'BEGIN{exit !(t > 0)}' 2>/dev/null; then
                # 1.5x safety margin, clamped to [120, 1800]
                wait_ci_timeout=$(awk -v p90="$p90_time" 'BEGIN{
                    t = p90 * 1.5;
                    if (t < 120) t = 120;
                    if (t > 1800) t = 1800;
                    printf "%d", t
                }')
            fi
        fi
        # Default fallback if no history
        [[ "$wait_ci_timeout" -eq 0 ]] && wait_ci_timeout=600
    fi
    auto_delete_branch=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_delete_branch) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_delete_branch" || "$auto_delete_branch" == "null" ]] && auto_delete_branch="true"
    auto_merge=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_merge) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_merge" || "$auto_merge" == "null" ]] && auto_merge="false"
    auto_approve=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.auto_approve) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_approve" || "$auto_approve" == "null" ]] && auto_approve="false"
    merge_strategy=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_strategy) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_strategy" || "$merge_strategy" == "null" ]] && merge_strategy=""
    # merge_strategy overrides merge_method if set (squash/merge/rebase)
    if [[ -n "$merge_strategy" ]]; then
        merge_method="$merge_strategy"
    fi

    # Find PR for current branch
    local pr_number
    pr_number=$(gh pr list --head "$GIT_BRANCH" --json number --jq '.[0].number' 2>/dev/null || echo "")

    if [[ -z "$pr_number" ]]; then
        warn "No PR found for branch $GIT_BRANCH — skipping merge"
        return 0
    fi

    info "Found PR #${pr_number} for branch ${GIT_BRANCH}"

    # Wait for CI checks to pass
    info "Waiting for CI checks (timeout: ${wait_ci_timeout}s)..."
    local elapsed=0
    local check_interval=15

    while [[ "$elapsed" -lt "$wait_ci_timeout" ]]; do
        local check_status
        check_status=$(gh pr checks "$pr_number" --json 'bucket,name' --jq '[.[] | .bucket] | unique | sort' 2>/dev/null || echo '["pending"]')

        # If all checks passed (only "pass" in buckets)
        if echo "$check_status" | jq -e '. == ["pass"]' &>/dev/null; then
            success "All CI checks passed"
            break
        fi

        # If any check failed
        if echo "$check_status" | jq -e 'any(. == "fail")' &>/dev/null; then
            error "CI checks failed — aborting merge"
            return 1
        fi

        sleep "$check_interval"
        elapsed=$((elapsed + check_interval))
    done

    # Record CI wait time for adaptive timeout calculation
    if [[ "$elapsed" -gt 0 ]]; then
        local repo_hash_ci_rec
        repo_hash_ci_rec=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
        local ci_times_dir="${HOME}/.shipwright/baselines/${repo_hash_ci_rec}"
        local ci_times_rec_file="${ci_times_dir}/ci-times.json"
        mkdir -p "$ci_times_dir"
        local ci_history="[]"
        if [[ -f "$ci_times_rec_file" ]]; then
            ci_history=$(jq '.times // []' "$ci_times_rec_file" 2>/dev/null || echo "[]")
        fi
        local updated_ci
        updated_ci=$(echo "$ci_history" | jq --arg t "$elapsed" '. + [($t | tonumber)] | .[-20:]' 2>/dev/null || echo "[$elapsed]")
        local tmp_ci
        tmp_ci=$(mktemp "${ci_times_dir}/ci-times.json.XXXXXX")
        jq -n --argjson times "$updated_ci" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{times: $times, updated: $updated}' > "$tmp_ci" 2>/dev/null
        mv "$tmp_ci" "$ci_times_rec_file" 2>/dev/null || true
    fi

    if [[ "$elapsed" -ge "$wait_ci_timeout" ]]; then
        warn "CI check timeout (${wait_ci_timeout}s) — proceeding with merge anyway"
    fi

    # Auto-approve if configured (for branch protection requiring reviews)
    if [[ "$auto_approve" == "true" ]]; then
        info "Auto-approving PR #${pr_number}..."
        gh pr review "$pr_number" --approve 2>/dev/null || warn "Auto-approve failed (may need different permissions)"
    fi

    # Merge the PR
    if [[ "$auto_merge" == "true" ]]; then
        info "Enabling auto-merge for PR #${pr_number} (strategy: ${merge_method})..."
        local auto_merge_args=("pr" "merge" "$pr_number" "--auto" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            auto_merge_args+=("--delete-branch")
        fi

        if gh "${auto_merge_args[@]}" 2>/dev/null; then
            success "Auto-merge enabled for PR #${pr_number} (strategy: ${merge_method})"
            emit_event "merge.auto_enabled" \
                "issue=${ISSUE_NUMBER:-0}" \
                "pr=$pr_number" \
                "strategy=$merge_method"
        else
            warn "Auto-merge not available — falling back to direct merge"
            # Fall through to direct merge below
            auto_merge="false"
        fi
    fi

    if [[ "$auto_merge" != "true" ]]; then
        info "Merging PR #${pr_number} (method: ${merge_method})..."
        local merge_args=("pr" "merge" "$pr_number" "--${merge_method}")
        if [[ "$auto_delete_branch" == "true" ]]; then
            merge_args+=("--delete-branch")
        fi

        if gh "${merge_args[@]}" 2>/dev/null; then
            success "PR #${pr_number} merged successfully"
        else
            error "Failed to merge PR #${pr_number}"
            return 1
        fi
    fi

    log_stage "merge" "PR #${pr_number} merged (strategy: ${merge_method}, auto_merge: ${auto_merge})"
}

stage_deploy() {
    CURRENT_STAGE_ID="deploy"
    local staging_cmd
    staging_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.staging_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$staging_cmd" == "null" ]] && staging_cmd=""

    local prod_cmd
    prod_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.production_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$prod_cmd" == "null" ]] && prod_cmd=""

    local rollback_cmd
    rollback_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""

    if [[ -z "$staging_cmd" && -z "$prod_cmd" ]]; then
        warn "No deploy commands configured — skipping"
        return 0
    fi

    # Create GitHub deployment tracking
    local gh_deploy_env="production"
    [[ -n "$staging_cmd" && -z "$prod_cmd" ]] && gh_deploy_env="staging"
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_start &>/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_start "$REPO_OWNER" "$REPO_NAME" "${GIT_BRANCH:-HEAD}" "$gh_deploy_env" 2>/dev/null || true
            info "GitHub Deployment: tracking as $gh_deploy_env"
        fi
    fi

    # ── Pre-deploy gates ──
    local pre_deploy_ci
    pre_deploy_ci=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_ci_status) // "true"' "$PIPELINE_CONFIG" 2>/dev/null) || true

    if [[ "${pre_deploy_ci:-true}" == "true" && "${NO_GITHUB:-false}" != "true" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        info "Pre-deploy gate: checking CI status..."
        local ci_failures
        ci_failures=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/commits/${GIT_BRANCH:-HEAD}/check-runs" \
            --jq '[.check_runs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped")] | length' 2>/dev/null || echo "0")
        if [[ "${ci_failures:-0}" -gt 0 ]]; then
            error "Pre-deploy gate FAILED: ${ci_failures} CI check(s) not passing"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: ${ci_failures} CI checks failing" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: all CI checks passing"
    fi

    local pre_deploy_min_cov
    pre_deploy_min_cov=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.pre_deploy_min_coverage) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    if [[ -n "${pre_deploy_min_cov:-}" && "${pre_deploy_min_cov}" != "null" && -f "$ARTIFACTS_DIR/test-coverage.json" ]]; then
        local actual_cov
        actual_cov=$(jq -r '.coverage_pct // 0' "$ARTIFACTS_DIR/test-coverage.json" 2>/dev/null || echo "0")
        if [[ "${actual_cov:-0}" -lt "$pre_deploy_min_cov" ]]; then
            error "Pre-deploy gate FAILED: coverage ${actual_cov}% < required ${pre_deploy_min_cov}%"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Pre-deploy gate: coverage ${actual_cov}% below minimum ${pre_deploy_min_cov}%" 2>/dev/null || true
            return 1
        fi
        success "Pre-deploy gate: coverage ${actual_cov}% >= ${pre_deploy_min_cov}%"
    fi

    # Post deploy start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "Deploy started"
    fi

    # ── Deploy strategy ──
    local deploy_strategy
    deploy_strategy=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.deploy_strategy) // "direct"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$deploy_strategy" == "null" ]] && deploy_strategy="direct"

    local canary_cmd promote_cmd switch_cmd health_url deploy_log
    canary_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.canary_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$canary_cmd" == "null" ]] && canary_cmd=""
    promote_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.promote_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$promote_cmd" == "null" ]] && promote_cmd=""
    switch_cmd=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.switch_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$switch_cmd" == "null" ]] && switch_cmd=""
    health_url=$(jq -r --arg id "deploy" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    deploy_log="$ARTIFACTS_DIR/deploy.log"

    case "$deploy_strategy" in
        canary)
            info "Canary deployment strategy..."
            if [[ -z "$canary_cmd" ]]; then
                warn "No canary_cmd configured — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying canary..."
                bash -c "$canary_cmd" >> "$deploy_log" 2>&1 || { error "Canary deploy failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local canary_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 10
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        if [[ "$_status" -ge 200 && "$_status" -lt 400 ]]; then
                            canary_healthy=$((canary_healthy + 1))
                        fi
                    done
                    if [[ "$canary_healthy" -lt 2 ]]; then
                        error "Canary health check failed ($canary_healthy/3 passed) — rolling back"
                        [[ -n "$rollback_cmd" ]] && bash -c "$rollback_cmd" 2>/dev/null || true
                        return 1
                    fi
                    success "Canary healthy ($canary_healthy/3 checks passed)"
                fi

                info "Promoting canary to full deployment..."
                if [[ -n "$promote_cmd" ]]; then
                    bash -c "$promote_cmd" >> "$deploy_log" 2>&1 || { error "Promote failed"; return 1; }
                fi
                success "Canary promoted"
            fi
            ;;
        blue-green)
            info "Blue-green deployment strategy..."
            if [[ -z "$staging_cmd" || -z "$switch_cmd" ]]; then
                warn "Blue-green requires staging_cmd + switch_cmd — falling back to direct"
                deploy_strategy="direct"
            else
                info "Deploying to inactive environment..."
                bash -c "$staging_cmd" >> "$deploy_log" 2>&1 || { error "Blue-green staging failed"; return 1; }

                if [[ -n "$health_url" ]]; then
                    local bg_healthy=0
                    local _chk
                    for _chk in 1 2 3; do
                        sleep 5
                        local _status
                        _status=$(curl -s -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "0")
                        [[ "$_status" -ge 200 && "$_status" -lt 400 ]] && bg_healthy=$((bg_healthy + 1))
                    done
                    if [[ "$bg_healthy" -lt 2 ]]; then
                        error "Blue-green health check failed — not switching"
                        return 1
                    fi
                fi

                info "Switching traffic..."
                bash -c "$switch_cmd" >> "$deploy_log" 2>&1 || { error "Traffic switch failed"; return 1; }
                success "Blue-green switch complete"
            fi
            ;;
    esac

    # ── Direct deployment (default or fallback) ──
    if [[ "$deploy_strategy" == "direct" ]]; then
        if [[ -n "$staging_cmd" ]]; then
            info "Deploying to staging..."
            bash -c "$staging_cmd" > "$ARTIFACTS_DIR/deploy-staging.log" 2>&1 || {
                error "Staging deploy failed"
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Staging deploy failed"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete &>/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Staging deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Staging deploy complete"
        fi

        if [[ -n "$prod_cmd" ]]; then
            info "Deploying to production..."
            bash -c "$prod_cmd" > "$ARTIFACTS_DIR/deploy-prod.log" 2>&1 || {
                error "Production deploy failed"
                if [[ -n "$rollback_cmd" ]]; then
                    warn "Rolling back..."
                    bash -c "$rollback_cmd" 2>&1 || error "Rollback also failed!"
                fi
                [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "Production deploy failed — rollback ${rollback_cmd:+attempted}"
                # Mark GitHub deployment as failed
                if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete &>/dev/null 2>&1; then
                    gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" false "Production deploy failed" 2>/dev/null || true
                fi
                return 1
            }
            success "Production deploy complete"
        fi
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Deploy complete**"
        gh_add_labels "$ISSUE_NUMBER" "deployed"
    fi

    # Mark GitHub deployment as successful
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_deploy_pipeline_complete &>/dev/null 2>&1; then
        if [[ -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            gh_deploy_pipeline_complete "$REPO_OWNER" "$REPO_NAME" "$gh_deploy_env" true "" 2>/dev/null || true
        fi
    fi

    log_stage "deploy" "Deploy complete"
}

stage_validate() {
    CURRENT_STAGE_ID="validate"
    local smoke_cmd
    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

    local health_url
    health_url=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""

    local close_issue
    close_issue=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.close_issue) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true

    # Smoke tests
    if [[ -n "$smoke_cmd" ]]; then
        info "Running smoke tests..."
        bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/smoke.log" 2>&1 || {
            error "Smoke tests failed"
            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh issue create --title "Deploy validation failed: $GOAL" \
                    --label "incident" --body "Pipeline smoke tests failed after deploy.

Related issue: ${GITHUB_ISSUE}
Branch: ${GIT_BRANCH}
PR: $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'unknown')" 2>/dev/null || true
            fi
            return 1
        }
        success "Smoke tests passed"
    fi

    # Health check with retry
    if [[ -n "$health_url" ]]; then
        info "Health check: $health_url"
        local attempts=0
        while [[ $attempts -lt 5 ]]; do
            if curl -sf "$health_url" >/dev/null 2>&1; then
                success "Health check passed"
                break
            fi
            attempts=$((attempts + 1))
            [[ $attempts -lt 5 ]] && { info "Retry ${attempts}/5..."; sleep 10; }
        done
        if [[ $attempts -ge 5 ]]; then
            error "Health check failed after 5 attempts"
            return 1
        fi
    fi

    # Compute total duration once for both issue close and wiki report
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    # Close original issue with comprehensive summary
    if [[ "$close_issue" == "true" && -n "$ISSUE_NUMBER" ]]; then
        gh issue close "$ISSUE_NUMBER" --comment "## ✅ Complete — Deployed & Validated

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |

_Closed automatically by \`shipwright pipeline\`_" 2>/dev/null || true

        gh_remove_label "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/complete"
        success "Issue #$ISSUE_NUMBER closed"
    fi

    # Push pipeline report to wiki
    local report="# Pipeline Report — ${GOAL}

| Metric | Value |
|--------|-------|
| Pipeline | \`${PIPELINE_NAME}\` |
| Branch | \`${GIT_BRANCH}\` |
| PR | $(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo 'N/A') |
| Duration | ${total_dur:-unknown} |
| Stages | $(echo "$STAGE_TIMINGS" | tr '|' '\n' | wc -l | xargs) completed |

## Stage Timings
$(echo "$STAGE_TIMINGS" | tr '|' '\n' | sed 's/^/- /')

## Artifacts
$(ls -1 "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/- /')

---
_Generated by \`shipwright pipeline\` at $(now_iso)_"
    gh_wiki_page "Pipeline-Report-${ISSUE_NUMBER:-inline}" "$report"

    log_stage "validate" "Validation complete"
}

stage_monitor() {
    CURRENT_STAGE_ID="monitor"

    # Read config from pipeline template
    local duration_minutes health_url error_threshold log_pattern log_cmd rollback_cmd auto_rollback
    duration_minutes=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.duration_minutes) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$duration_minutes" || "$duration_minutes" == "null" ]] && duration_minutes=5
    health_url=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.health_url) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$health_url" == "null" ]] && health_url=""
    error_threshold=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.error_threshold) // 5' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$error_threshold" || "$error_threshold" == "null" ]] && error_threshold=5

    # Adaptive monitor: use historical baselines if available
    local repo_hash
    repo_hash=$(echo "${PROJECT_ROOT:-$(pwd)}" | cksum | awk '{print $1}')
    local baseline_file="${HOME}/.shipwright/baselines/${repo_hash}/deploy-monitor.json"
    if [[ -f "$baseline_file" ]]; then
        local hist_duration hist_threshold
        hist_duration=$(jq -r '.p90_stabilization_minutes // empty' "$baseline_file" 2>/dev/null || true)
        hist_threshold=$(jq -r '.p90_error_threshold // empty' "$baseline_file" 2>/dev/null || true)
        if [[ -n "$hist_duration" && "$hist_duration" != "null" ]]; then
            duration_minutes="$hist_duration"
            info "Monitor duration: ${duration_minutes}m ${DIM}(from baseline)${RESET}"
        fi
        if [[ -n "$hist_threshold" && "$hist_threshold" != "null" ]]; then
            error_threshold="$hist_threshold"
            info "Error threshold: ${error_threshold} ${DIM}(from baseline)${RESET}"
        fi
    fi
    log_pattern=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_pattern) // "ERROR|FATAL|PANIC"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$log_pattern" || "$log_pattern" == "null" ]] && log_pattern="ERROR|FATAL|PANIC"
    log_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.log_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$log_cmd" == "null" ]] && log_cmd=""
    rollback_cmd=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.rollback_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ "$rollback_cmd" == "null" ]] && rollback_cmd=""
    auto_rollback=$(jq -r --arg id "monitor" '(.stages[] | select(.id == $id) | .config.auto_rollback) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$auto_rollback" || "$auto_rollback" == "null" ]] && auto_rollback="false"

    if [[ -z "$health_url" && -z "$log_cmd" ]]; then
        warn "No health_url or log_cmd configured — skipping monitor stage"
        log_stage "monitor" "Skipped (no monitoring configured)"
        return 0
    fi

    local report_file="$ARTIFACTS_DIR/monitor-report.md"
    local total_errors=0
    local poll_interval=30  # seconds between polls
    local total_polls=$(( (duration_minutes * 60) / poll_interval ))
    [[ "$total_polls" -lt 1 ]] && total_polls=1

    info "Post-deploy monitoring: ${duration_minutes}m (${total_polls} polls, threshold: ${error_threshold} errors)"

    emit_event "monitor.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_minutes=$duration_minutes" \
        "error_threshold=$error_threshold"

    {
        echo "# Post-Deploy Monitor Report"
        echo ""
        echo "- Duration: ${duration_minutes} minutes"
        echo "- Health URL: ${health_url:-none}"
        echo "- Log command: ${log_cmd:-none}"
        echo "- Error threshold: ${error_threshold}"
        echo "- Auto-rollback: ${auto_rollback}"
        echo ""
        echo "## Poll Results"
        echo ""
    } > "$report_file"

    local poll=0
    local health_failures=0
    local log_errors=0
    while [[ "$poll" -lt "$total_polls" ]]; do
        poll=$((poll + 1))
        local poll_time
        poll_time=$(now_iso)

        # Health URL check
        if [[ -n "$health_url" ]]; then
            local http_status
            http_status=$(curl -sf -o /dev/null -w "%{http_code}" "$health_url" 2>/dev/null || echo "000")
            if [[ "$http_status" -ge 200 && "$http_status" -lt 400 ]]; then
                echo "- [${poll_time}] Health: ✅ (HTTP ${http_status})" >> "$report_file"
            else
                health_failures=$((health_failures + 1))
                total_errors=$((total_errors + 1))
                echo "- [${poll_time}] Health: ❌ (HTTP ${http_status})" >> "$report_file"
                warn "Health check failed: HTTP ${http_status}"
            fi
        fi

        # Log command check
        if [[ -n "$log_cmd" ]]; then
            local log_output
            log_output=$(bash -c "$log_cmd" 2>/dev/null || true)
            local error_count=0
            if [[ -n "$log_output" ]]; then
                error_count=$(echo "$log_output" | grep -cE "$log_pattern" 2>/dev/null || true)
                error_count="${error_count:-0}"
            fi
            if [[ "$error_count" -gt 0 ]]; then
                log_errors=$((log_errors + error_count))
                total_errors=$((total_errors + error_count))
                echo "- [${poll_time}] Logs: ⚠️ ${error_count} error(s) matching '${log_pattern}'" >> "$report_file"
                warn "Log errors detected: ${error_count}"
            else
                echo "- [${poll_time}] Logs: ✅ clean" >> "$report_file"
            fi
        fi

        emit_event "monitor.check" \
            "issue=${ISSUE_NUMBER:-0}" \
            "poll=$poll" \
            "total_errors=$total_errors" \
            "health_failures=$health_failures"

        # Check threshold
        if [[ "$total_errors" -ge "$error_threshold" ]]; then
            error "Error threshold exceeded: ${total_errors} >= ${error_threshold}"

            echo "" >> "$report_file"
            echo "## ❌ THRESHOLD EXCEEDED" >> "$report_file"
            echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"

            emit_event "monitor.alert" \
                "issue=${ISSUE_NUMBER:-0}" \
                "total_errors=$total_errors" \
                "threshold=$error_threshold"

            # Auto-rollback if configured
            if [[ "$auto_rollback" == "true" && -n "$rollback_cmd" ]]; then
                warn "Auto-rolling back..."
                echo "" >> "$report_file"
                echo "## Rollback" >> "$report_file"

                if bash -c "$rollback_cmd" >> "$report_file" 2>&1; then
                    success "Rollback executed"
                    echo "Rollback: ✅ success" >> "$report_file"

                    # Post-rollback smoke test verification
                    local smoke_cmd
                    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
                    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

                    if [[ -n "$smoke_cmd" ]]; then
                        info "Verifying rollback with smoke tests..."
                        if bash -c "$smoke_cmd" > "$ARTIFACTS_DIR/rollback-smoke.log" 2>&1; then
                            success "Rollback verified — smoke tests pass"
                            echo "Rollback verification: ✅ smoke tests pass" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=pass"
                        else
                            error "Rollback verification FAILED — smoke tests still failing"
                            echo "Rollback verification: ❌ smoke tests FAILED — manual intervention required" >> "$report_file"
                            emit_event "monitor.rollback_verified" \
                                "issue=${ISSUE_NUMBER:-0}" \
                                "status=fail"
                            if [[ -n "$ISSUE_NUMBER" ]]; then
                                gh_comment_issue "$ISSUE_NUMBER" "🚨 **Rollback executed but verification failed** — smoke tests still failing after rollback. Manual intervention required.

Smoke command: \`${smoke_cmd}\`
Log: see \`pipeline-artifacts/rollback-smoke.log\`" 2>/dev/null || true
                            fi
                        fi
                    fi
                else
                    error "Rollback failed!"
                    echo "Rollback: ❌ failed" >> "$report_file"
                fi

                emit_event "monitor.rollback" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "total_errors=$total_errors"

                # Post to GitHub
                if [[ -n "$ISSUE_NUMBER" ]]; then
                    gh_comment_issue "$ISSUE_NUMBER" "🚨 **Auto-rollback triggered** — ${total_errors} errors exceeded threshold (${error_threshold})

Rollback command: \`${rollback_cmd}\`" 2>/dev/null || true

                    # Create hotfix issue
                    if [[ "$GH_AVAILABLE" == "true" ]]; then
                        gh issue create \
                            --title "Hotfix: Deploy regression for ${GOAL}" \
                            --label "hotfix,incident" \
                            --body "Auto-rollback triggered during post-deploy monitoring.

**Original issue:** ${GITHUB_ISSUE:-N/A}
**Errors detected:** ${total_errors}
**Threshold:** ${error_threshold}
**Branch:** ${GIT_BRANCH}

## Monitor Report
$(cat "$report_file")

---
_Created automatically by \`shipwright pipeline\` monitor stage_" 2>/dev/null || true
                    fi
                fi
            fi

            log_stage "monitor" "Failed — ${total_errors} errors (threshold: ${error_threshold})"
            return 1
        fi

        # Sleep between polls (skip on last poll)
        if [[ "$poll" -lt "$total_polls" ]]; then
            sleep "$poll_interval"
        fi
    done

    # Monitoring complete — all clear
    echo "" >> "$report_file"
    echo "## ✅ Monitoring Complete" >> "$report_file"
    echo "Total errors: ${total_errors} (threshold: ${error_threshold})" >> "$report_file"
    echo "Health failures: ${health_failures}" >> "$report_file"
    echo "Log errors: ${log_errors}" >> "$report_file"

    success "Post-deploy monitoring clean (${total_errors} errors in ${duration_minutes}m)"

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Post-deploy monitoring passed** — ${duration_minutes}m, ${total_errors} errors" 2>/dev/null || true
    fi

    log_stage "monitor" "Clean — ${total_errors} errors in ${duration_minutes}m"

    # Record baseline for adaptive monitoring on future runs
    local baseline_dir="${HOME}/.shipwright/baselines/${repo_hash}"
    mkdir -p "$baseline_dir" 2>/dev/null || true
    local baseline_tmp
    baseline_tmp="$(mktemp)"
    if [[ -f "${baseline_dir}/deploy-monitor.json" ]]; then
        # Append to history and recalculate p90
        jq --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '.history += [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}] |
             .p90_stabilization_minutes = ([.history[].duration_minutes] | sort | .[length * 9 / 10 | floor]) |
             .p90_error_threshold = (([.history[].errors] | sort | .[length * 9 / 10 | floor]) + 2) |
             .updated_at = now' \
            "${baseline_dir}/deploy-monitor.json" > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    else
        jq -n --arg dur "$duration_minutes" --arg errs "$total_errors" \
            '{history: [{"duration_minutes": ($dur | tonumber), "errors": ($errs | tonumber)}],
              p90_stabilization_minutes: ($dur | tonumber),
              p90_error_threshold: (($errs | tonumber) + 2),
              updated_at: now}' \
            > "$baseline_tmp" 2>/dev/null && \
            mv "$baseline_tmp" "${baseline_dir}/deploy-monitor.json" || rm -f "$baseline_tmp"
    fi
}

# ─── Multi-Dimensional Quality Checks ─────────────────────────────────────
# Beyond tests: security, bundle size, perf regression, API compat, coverage

quality_check_security() {
    info "Security audit..."
    local audit_log="$ARTIFACTS_DIR/security-audit.log"
    local audit_exit=0
    local tool_found=false

    # Try npm audit
    if [[ -f "package.json" ]] && command -v npm &>/dev/null; then
        tool_found=true
        npm audit --production 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try pip-audit
    elif [[ -f "requirements.txt" || -f "pyproject.toml" ]] && command -v pip-audit &>/dev/null; then
        tool_found=true
        pip-audit 2>&1 | tee "$audit_log" || audit_exit=$?
    # Try cargo audit
    elif [[ -f "Cargo.toml" ]] && command -v cargo-audit &>/dev/null; then
        tool_found=true
        cargo audit 2>&1 | tee "$audit_log" || audit_exit=$?
    fi

    if [[ "$tool_found" != "true" ]]; then
        info "No security audit tool found — skipping"
        echo "No audit tool available" > "$audit_log"
        return 0
    fi

    # Parse results for critical/high severity
    local critical_count high_count
    critical_count=$(grep -ciE 'critical' "$audit_log" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    high_count=$(grep -ciE 'high' "$audit_log" 2>/dev/null || true)
    high_count="${high_count:-0}"

    emit_event "quality.security" \
        "issue=${ISSUE_NUMBER:-0}" \
        "critical=$critical_count" \
        "high=$high_count"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Security audit: ${critical_count} critical, ${high_count} high"
        return 1
    fi

    success "Security audit: clean"
    return 0
}

quality_check_bundle_size() {
    info "Bundle size check..."
    local metrics_log="$ARTIFACTS_DIR/bundle-metrics.log"
    local bundle_size=0
    local bundle_dir=""

    # Find build output directory — check config files first, then common dirs
    # Parse tsconfig.json outDir
    if [[ -z "$bundle_dir" && -f "tsconfig.json" ]]; then
        local ts_out
        ts_out=$(jq -r '.compilerOptions.outDir // empty' tsconfig.json 2>/dev/null || true)
        [[ -n "$ts_out" && -d "$ts_out" ]] && bundle_dir="$ts_out"
    fi
    # Parse package.json build script for output hints
    if [[ -z "$bundle_dir" && -f "package.json" ]]; then
        local build_script
        build_script=$(jq -r '.scripts.build // ""' package.json 2>/dev/null || true)
        if [[ -n "$build_script" ]]; then
            # Check for common output flags: --outDir, -o, --out-dir
            local parsed_out
            parsed_out=$(echo "$build_script" | grep -oE '(--outDir|--out-dir|-o)\s+[^ ]+' 2>/dev/null | awk '{print $NF}' | head -1 || true)
            [[ -n "$parsed_out" && -d "$parsed_out" ]] && bundle_dir="$parsed_out"
        fi
    fi
    # Fallback: check common directories
    if [[ -z "$bundle_dir" ]]; then
        for dir in dist build out .next target; do
            if [[ -d "$dir" ]]; then
                bundle_dir="$dir"
                break
            fi
        done
    fi

    if [[ -z "$bundle_dir" ]]; then
        info "No build output directory found — skipping bundle check"
        echo "No build directory" > "$metrics_log"
        return 0
    fi

    bundle_size=$(du -sk "$bundle_dir" 2>/dev/null | cut -f1 || echo "0")
    local bundle_size_human
    bundle_size_human=$(du -sh "$bundle_dir" 2>/dev/null | cut -f1 || echo "unknown")

    echo "Bundle directory: $bundle_dir" > "$metrics_log"
    echo "Size: ${bundle_size}KB (${bundle_size_human})" >> "$metrics_log"

    emit_event "quality.bundle" \
        "issue=${ISSUE_NUMBER:-0}" \
        "size_kb=$bundle_size" \
        "directory=$bundle_dir"

    # Adaptive bundle size check: statistical deviation from historical mean
    local repo_hash_bundle
    repo_hash_bundle=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local bundle_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_bundle}"
    local bundle_history_file="${bundle_baselines_dir}/bundle-history.json"

    local bundle_history="[]"
    if [[ -f "$bundle_history_file" ]]; then
        bundle_history=$(jq '.sizes // []' "$bundle_history_file" 2>/dev/null || echo "[]")
    fi

    local bundle_hist_count
    bundle_hist_count=$(echo "$bundle_history" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$bundle_hist_count" -ge 3 ]]; then
        # Statistical check: alert on growth > 2σ from historical mean
        local mean_size stddev_size
        mean_size=$(echo "$bundle_history" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_size=$(echo "$bundle_history" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Adaptive tolerance: small repos (<1MB mean) get wider tolerance (3σ), large repos get 2σ
        local sigma_mult
        sigma_mult=$(awk -v mean="$mean_size" 'BEGIN{ print (mean < 1024 ? 3 : 2) }')
        local adaptive_max
        adaptive_max=$(awk -v mean="$mean_size" -v sd="$stddev_size" -v mult="$sigma_mult" \
            'BEGIN{ t = mean + mult*sd; min_t = mean * 1.1; printf "%.0f", (t > min_t ? t : min_t) }')

        echo "History: ${bundle_hist_count} runs | Mean: ${mean_size}KB | StdDev: ${stddev_size}KB | Max: ${adaptive_max}KB (${sigma_mult}σ)" >> "$metrics_log"

        if [[ "$bundle_size" -gt "$adaptive_max" ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v mean="$mean_size" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Bundle size ${growth_pct}% above average (${mean_size}KB → ${bundle_size}KB, ${sigma_mult}σ threshold: ${adaptive_max}KB)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline with hardcoded 20% (not enough history)
        local baseline_size=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_size=$(bash "$SCRIPT_DIR/sw-memory.sh" get "bundle_size_kb" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_size" && "$baseline_size" -gt 0 ]] 2>/dev/null; then
            local growth_pct
            growth_pct=$(awk -v cur="$bundle_size" -v base="$baseline_size" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_size}KB | Growth: ${growth_pct}%" >> "$metrics_log"
            if [[ "$growth_pct" -gt 20 ]]; then
                warn "Bundle size grew ${growth_pct}% (${baseline_size}KB → ${bundle_size}KB)"
                return 1
            fi
        fi
    fi

    # Append current size to rolling history (keep last 10)
    mkdir -p "$bundle_baselines_dir"
    local updated_bundle_hist
    updated_bundle_hist=$(echo "$bundle_history" | jq --arg sz "$bundle_size" '
        . + [($sz | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$bundle_size]")
    local tmp_bundle_hist
    tmp_bundle_hist=$(mktemp "${bundle_baselines_dir}/bundle-history.json.XXXXXX")
    jq -n --argjson sizes "$updated_bundle_hist" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{sizes: $sizes, updated: $updated}' > "$tmp_bundle_hist" 2>/dev/null
    mv "$tmp_bundle_hist" "$bundle_history_file" 2>/dev/null || true

    # Intelligence: identify top dependency bloaters
    if type intelligence_search_memory &>/dev/null 2>&1 && [[ -f "package.json" ]] && command -v jq &>/dev/null; then
        local dep_sizes=""
        local deps
        deps=$(jq -r '.dependencies // {} | keys[]' package.json 2>/dev/null || true)
        if [[ -n "$deps" ]]; then
            while IFS= read -r dep; do
                [[ -z "$dep" ]] && continue
                local dep_dir="node_modules/${dep}"
                if [[ -d "$dep_dir" ]]; then
                    local dep_size
                    dep_size=$(du -sk "$dep_dir" 2>/dev/null | cut -f1 || echo "0")
                    dep_sizes="${dep_sizes}${dep_size} ${dep}
"
                fi
            done <<< "$deps"
            if [[ -n "$dep_sizes" ]]; then
                local top_bloaters
                top_bloaters=$(echo "$dep_sizes" | sort -rn | head -3)
                if [[ -n "$top_bloaters" ]]; then
                    echo "" >> "$metrics_log"
                    echo "Top 3 dependency sizes:" >> "$metrics_log"
                    echo "$top_bloaters" | while IFS=' ' read -r sz nm; do
                        [[ -z "$nm" ]] && continue
                        echo "  ${nm}: ${sz}KB" >> "$metrics_log"
                    done
                    info "Top bloaters: $(echo "$top_bloaters" | head -1 | awk '{print $2 ": " $1 "KB"}')"
                fi
            fi
        fi
    fi

    info "Bundle size: ${bundle_size_human}${bundle_hist_count:+ (${bundle_hist_count} historical samples)}"
    return 0
}

quality_check_perf_regression() {
    info "Performance regression check..."
    local metrics_log="$ARTIFACTS_DIR/perf-metrics.log"
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping perf check"
        echo "No test results available" > "$metrics_log"
        return 0
    fi

    # Extract test suite duration — multi-framework patterns
    local duration_ms=""
    # Jest/Vitest: "Time: 12.34 s" or "Duration  12.34s"
    duration_ms=$(grep -oE 'Time:\s*[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'Duration\s+[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # pytest: "passed in 12.34s" or "====== 5 passed in 12.34 seconds ======"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'passed in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Go test: "ok  pkg  12.345s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '^ok\s+\S+\s+[0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+s' | grep -oE '[0-9.]+' | tail -1 || true)
    # Cargo test: "test result: ok. ... finished in 12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE 'finished in [0-9.]+s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    # Generic: "12.34 seconds" or "12.34s"
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '[0-9.]+ ?s(econds?)?' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$duration_ms" ]]; then
        local intel_enabled="false"
        local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
        if [[ -f "$daemon_cfg" ]]; then
            intel_enabled=$(jq -r '.intelligence.enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled" == "true" ]] && command -v claude &>/dev/null; then
            local tail_output
            tail_output=$(tail -30 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_output" ]]; then
                duration_ms=$(claude --print -p "Extract ONLY the total test suite duration in seconds from this output. Reply with ONLY a number (e.g. 12.34). If no duration found, reply NONE.

$tail_output" < /dev/null 2>/dev/null | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$duration_ms" == "NONE" ]] && duration_ms=""
            fi
        fi
    fi

    if [[ -z "$duration_ms" ]]; then
        info "Could not extract test duration — skipping perf check"
        echo "Duration not parseable" > "$metrics_log"
        return 0
    fi

    echo "Test duration: ${duration_ms}s" > "$metrics_log"

    emit_event "quality.perf" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_s=$duration_ms"

    # Adaptive performance check: 2σ from rolling 10-run average
    local repo_hash_perf
    repo_hash_perf=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local perf_baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_perf}"
    local perf_history_file="${perf_baselines_dir}/perf-history.json"

    # Read historical durations (rolling window of last 10 runs)
    local history_json="[]"
    if [[ -f "$perf_history_file" ]]; then
        history_json=$(jq '.durations // []' "$perf_history_file" 2>/dev/null || echo "[]")
    fi

    local history_count
    history_count=$(echo "$history_json" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$history_count" -ge 3 ]]; then
        # Calculate mean and standard deviation from history
        local mean_dur stddev_dur
        mean_dur=$(echo "$history_json" | jq 'add / length' 2>/dev/null || echo "0")
        stddev_dur=$(echo "$history_json" | jq '
            (add / length) as $mean |
            (map(. - $mean | . * .) | add / length | sqrt)
        ' 2>/dev/null || echo "0")

        # Threshold: mean + 2σ (but at least 10% above mean)
        local adaptive_threshold
        adaptive_threshold=$(awk -v mean="$mean_dur" -v sd="$stddev_dur" \
            'BEGIN{ t = mean + 2*sd; min_t = mean * 1.1; printf "%.2f", (t > min_t ? t : min_t) }')

        echo "History: ${history_count} runs | Mean: ${mean_dur}s | StdDev: ${stddev_dur}s | Threshold: ${adaptive_threshold}s" >> "$metrics_log"

        if awk -v cur="$duration_ms" -v thresh="$adaptive_threshold" 'BEGIN{exit !(cur > thresh)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v mean="$mean_dur" 'BEGIN{printf "%d", ((cur - mean) / mean) * 100}')
            warn "Tests ${slowdown_pct}% slower than rolling average (${mean_dur}s → ${duration_ms}s, threshold: ${adaptive_threshold}s)"
            return 1
        fi
    else
        # Fallback: legacy memory baseline with hardcoded 30% (not enough history)
        local baseline_dur=""
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            baseline_dur=$(bash "$SCRIPT_DIR/sw-memory.sh" get "test_duration_s" 2>/dev/null) || true
        fi
        if [[ -n "$baseline_dur" ]] && awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
            local slowdown_pct
            slowdown_pct=$(awk -v cur="$duration_ms" -v base="$baseline_dur" 'BEGIN{printf "%d", ((cur - base) / base) * 100}')
            echo "Baseline: ${baseline_dur}s | Slowdown: ${slowdown_pct}%" >> "$metrics_log"
            if [[ "$slowdown_pct" -gt 30 ]]; then
                warn "Tests ${slowdown_pct}% slower (${baseline_dur}s → ${duration_ms}s)"
                return 1
            fi
        fi
    fi

    # Append current duration to rolling history (keep last 10)
    mkdir -p "$perf_baselines_dir"
    local updated_history
    updated_history=$(echo "$history_json" | jq --arg dur "$duration_ms" '
        . + [($dur | tonumber)] | .[-10:]
    ' 2>/dev/null || echo "[$duration_ms]")
    local tmp_perf_hist
    tmp_perf_hist=$(mktemp "${perf_baselines_dir}/perf-history.json.XXXXXX")
    jq -n --argjson durations "$updated_history" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{durations: $durations, updated: $updated}' > "$tmp_perf_hist" 2>/dev/null
    mv "$tmp_perf_hist" "$perf_history_file" 2>/dev/null || true

    info "Test duration: ${duration_ms}s${history_count:+ (${history_count} historical samples)}"
    return 0
}

quality_check_api_compat() {
    info "API compatibility check..."
    local compat_log="$ARTIFACTS_DIR/api-compat.log"

    # Look for OpenAPI/Swagger specs — search beyond hardcoded paths
    local spec_file=""
    for candidate in openapi.json openapi.yaml swagger.json swagger.yaml api/openapi.json docs/openapi.yaml; do
        if [[ -f "$candidate" ]]; then
            spec_file="$candidate"
            break
        fi
    done
    # Broader search if nothing found at common paths
    if [[ -z "$spec_file" ]]; then
        spec_file=$(find . -maxdepth 4 \( -name "openapi*.json" -o -name "openapi*.yaml" -o -name "openapi*.yml" -o -name "swagger*.json" -o -name "swagger*.yaml" -o -name "swagger*.yml" \) -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$spec_file" ]]; then
        info "No OpenAPI/Swagger spec found — skipping API compat check"
        echo "No API spec found" > "$compat_log"
        return 0
    fi

    # Check if spec was modified in this branch
    local spec_changed
    spec_changed=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -c "$(basename "$spec_file")" || true)
    spec_changed="${spec_changed:-0}"

    if [[ "$spec_changed" -eq 0 ]]; then
        info "API spec unchanged"
        echo "Spec unchanged" > "$compat_log"
        return 0
    fi

    # Diff the spec against base branch
    local old_spec new_spec
    old_spec=$(git show "${BASE_BRANCH}:${spec_file}" 2>/dev/null || true)
    new_spec=$(cat "$spec_file" 2>/dev/null || true)

    if [[ -z "$old_spec" ]]; then
        info "New API spec — no baseline to compare"
        echo "New spec, no baseline" > "$compat_log"
        return 0
    fi

    # Check for breaking changes: removed endpoints, changed methods
    local removed_endpoints=""
    if command -v jq &>/dev/null && [[ "$spec_file" == *.json ]]; then
        local old_paths new_paths
        old_paths=$(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort || true)
        new_paths=$(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort || true)
        removed_endpoints=$(comm -23 <(echo "$old_paths") <(echo "$new_paths") 2>/dev/null || true)
    fi

    # Enhanced schema diff: parameter changes, response schema, auth changes
    local param_changes="" schema_changes=""
    if command -v jq &>/dev/null && [[ "$spec_file" == *.json ]]; then
        # Detect parameter changes on existing endpoints
        local common_paths
        common_paths=$(comm -12 <(echo "$old_spec" | jq -r '.paths | keys[]' 2>/dev/null | sort) <(jq -r '.paths | keys[]' "$spec_file" 2>/dev/null | sort) 2>/dev/null || true)
        if [[ -n "$common_paths" ]]; then
            while IFS= read -r path; do
                [[ -z "$path" ]] && continue
                local old_params new_params
                old_params=$(echo "$old_spec" | jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' 2>/dev/null | sort || true)
                new_params=$(jq -r --arg p "$path" '.paths[$p] | to_entries[] | .value.parameters // [] | .[].name' "$spec_file" 2>/dev/null | sort || true)
                local removed_params
                removed_params=$(comm -23 <(echo "$old_params") <(echo "$new_params") 2>/dev/null || true)
                [[ -n "$removed_params" ]] && param_changes="${param_changes}${path}: removed params: ${removed_params}
"
            done <<< "$common_paths"
        fi
    fi

    # Intelligence: semantic API diff for complex changes
    local semantic_diff=""
    if type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null; then
        local spec_git_diff
        spec_git_diff=$(git diff "${BASE_BRANCH}...HEAD" -- "$spec_file" 2>/dev/null | head -200 || true)
        if [[ -n "$spec_git_diff" ]]; then
            semantic_diff=$(claude --print --output-format text -p "Analyze this API spec diff for breaking changes. List: removed endpoints, changed parameters, altered response schemas, auth changes. Be concise.

${spec_git_diff}" --model haiku < /dev/null 2>/dev/null || true)
        fi
    fi

    {
        echo "Spec: $spec_file"
        echo "Changed: yes"
        if [[ -n "$removed_endpoints" ]]; then
            echo "BREAKING — Removed endpoints:"
            echo "$removed_endpoints"
        fi
        if [[ -n "$param_changes" ]]; then
            echo "BREAKING — Parameter changes:"
            echo "$param_changes"
        fi
        if [[ -n "$semantic_diff" ]]; then
            echo ""
            echo "Semantic analysis:"
            echo "$semantic_diff"
        fi
        if [[ -z "$removed_endpoints" && -z "$param_changes" ]]; then
            echo "No breaking changes detected"
        fi
    } > "$compat_log"

    if [[ -n "$removed_endpoints" || -n "$param_changes" ]]; then
        local issue_count=0
        [[ -n "$removed_endpoints" ]] && issue_count=$((issue_count + $(echo "$removed_endpoints" | wc -l | xargs)))
        [[ -n "$param_changes" ]] && issue_count=$((issue_count + $(echo "$param_changes" | grep -c '.' || true)))
        warn "API breaking changes: ${issue_count} issue(s) found"
        return 1
    fi

    success "API compatibility: no breaking changes"
    return 0
}

quality_check_coverage() {
    info "Coverage analysis..."
    local test_log="$ARTIFACTS_DIR/test-results.log"

    if [[ ! -f "$test_log" ]]; then
        info "No test results — skipping coverage check"
        return 0
    fi

    # Extract coverage percentage using shared parser
    local coverage=""
    coverage=$(parse_coverage_from_output "$test_log")

    # Claude fallback: parse test output when no pattern matches
    if [[ -z "$coverage" ]]; then
        local intel_enabled_cov="false"
        local daemon_cfg_cov="${PROJECT_ROOT}/.claude/daemon-config.json"
        if [[ -f "$daemon_cfg_cov" ]]; then
            intel_enabled_cov=$(jq -r '.intelligence.enabled // false' "$daemon_cfg_cov" 2>/dev/null || echo "false")
        fi
        if [[ "$intel_enabled_cov" == "true" ]] && command -v claude &>/dev/null; then
            local tail_cov_output
            tail_cov_output=$(tail -40 "$test_log" 2>/dev/null || true)
            if [[ -n "$tail_cov_output" ]]; then
                coverage=$(claude --print -p "Extract ONLY the overall code coverage percentage from this test output. Reply with ONLY a number (e.g. 85.5). If no coverage found, reply NONE.

$tail_cov_output" < /dev/null 2>/dev/null | grep -oE '^[0-9.]+$' | head -1 || true)
                [[ "$coverage" == "NONE" ]] && coverage=""
            fi
        fi
    fi

    if [[ -z "$coverage" ]]; then
        info "Could not extract coverage — skipping"
        return 0
    fi

    emit_event "quality.coverage" \
        "issue=${ISSUE_NUMBER:-0}" \
        "coverage=$coverage"

    # Check against pipeline config minimum
    local coverage_min
    coverage_min=$(jq -r --arg id "test" '(.stages[] | select(.id == $id) | .config.coverage_min) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$coverage_min" || "$coverage_min" == "null" ]] && coverage_min=0

    # Adaptive baseline: read from baselines file, enforce no-regression (>= baseline - 2%)
    local repo_hash_cov
    repo_hash_cov=$(echo -n "$PROJECT_ROOT" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local baselines_dir="${HOME}/.shipwright/baselines/${repo_hash_cov}"
    local coverage_baseline_file="${baselines_dir}/coverage.json"

    local baseline_coverage=""
    if [[ -f "$coverage_baseline_file" ]]; then
        baseline_coverage=$(jq -r '.baseline // empty' "$coverage_baseline_file" 2>/dev/null) || true
    fi
    # Fallback: try legacy memory baseline
    if [[ -z "$baseline_coverage" ]] && [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        baseline_coverage=$(bash "$SCRIPT_DIR/sw-memory.sh" get "coverage_pct" 2>/dev/null) || true
    fi

    local dropped=false
    if [[ -n "$baseline_coverage" && "$baseline_coverage" != "0" ]] && awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(base > 0)}' 2>/dev/null; then
        # Adaptive: allow 2% regression tolerance from baseline
        local min_allowed
        min_allowed=$(awk -v base="$baseline_coverage" 'BEGIN{printf "%d", base - 2}')
        if awk -v cur="$coverage" -v min="$min_allowed" 'BEGIN{exit !(cur < min)}' 2>/dev/null; then
            warn "Coverage regression: ${baseline_coverage}% → ${coverage}% (adaptive min: ${min_allowed}%)"
            dropped=true
        fi
    fi

    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null && awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
        warn "Coverage ${coverage}% below minimum ${coverage_min}%"
        return 1
    fi

    if $dropped; then
        return 1
    fi

    # Update baseline on success (first run or improvement)
    if [[ -z "$baseline_coverage" ]] || awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(cur >= base)}' 2>/dev/null; then
        mkdir -p "$baselines_dir"
        local tmp_cov_baseline
        tmp_cov_baseline=$(mktemp "${baselines_dir}/coverage.json.XXXXXX")
        jq -n --arg baseline "$coverage" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{baseline: ($baseline | tonumber), updated: $updated}' > "$tmp_cov_baseline" 2>/dev/null
        mv "$tmp_cov_baseline" "$coverage_baseline_file" 2>/dev/null || true
    fi

    info "Coverage: ${coverage}%${baseline_coverage:+ (baseline: ${baseline_coverage}%)}"
    return 0
}

# ─── Compound Quality Checks ──────────────────────────────────────────────
# Adversarial review, negative prompting, E2E validation, and DoD audit.
# Feeds findings back into a self-healing rebuild loop for automatic fixes.

run_adversarial_review() {
    local diff_content
    diff_content=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)

    if [[ -z "$diff_content" ]]; then
        info "No diff to review"
        return 0
    fi

    # Delegate to sw-adversarial.sh module when available (uses intelligence cache)
    if type adversarial_review &>/dev/null 2>&1; then
        info "Using intelligence-backed adversarial review..."
        local json_result
        json_result=$(adversarial_review "$diff_content" "${GOAL:-}" 2>/dev/null || echo "[]")

        # Save raw JSON result
        echo "$json_result" > "$ARTIFACTS_DIR/adversarial-review.json"

        # Convert JSON findings to markdown for compatibility with compound_rebuild_with_feedback
        local critical_count high_count
        critical_count=$(echo "$json_result" | jq '[.[] | select(.severity == "critical")] | length' 2>/dev/null || echo "0")
        high_count=$(echo "$json_result" | jq '[.[] | select(.severity == "high")] | length' 2>/dev/null || echo "0")
        local total_findings
        total_findings=$(echo "$json_result" | jq 'length' 2>/dev/null || echo "0")

        # Generate markdown report from JSON
        {
            echo "# Adversarial Review (Intelligence-backed)"
            echo ""
            echo "Total findings: ${total_findings} (${critical_count} critical, ${high_count} high)"
            echo ""
            echo "$json_result" | jq -r '.[] | "- **[\(.severity // "unknown")]** \(.location // "unknown") — \(.description // .concern // "no description")"' 2>/dev/null || true
        } > "$ARTIFACTS_DIR/adversarial-review.md"

        emit_event "adversarial.delegated" \
            "issue=${ISSUE_NUMBER:-0}" \
            "findings=$total_findings" \
            "critical=$critical_count" \
            "high=$high_count"

        if [[ "$critical_count" -gt 0 ]]; then
            warn "Adversarial review: ${critical_count} critical, ${high_count} high"
            return 1
        elif [[ "$high_count" -gt 0 ]]; then
            warn "Adversarial review: ${high_count} high-severity issues"
            return 1
        fi

        success "Adversarial review: clean"
        return 0
    fi

    # Fallback: inline Claude call when module not loaded

    # Inject previous adversarial findings from memory
    local adv_memory=""
    if type intelligence_search_memory &>/dev/null 2>&1; then
        adv_memory=$(intelligence_search_memory "adversarial review security findings for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    local prompt="You are a hostile code reviewer. Your job is to find EVERY possible issue in this diff.
Look for:
- Bugs (logic errors, off-by-one, null/undefined access, race conditions)
- Security vulnerabilities (injection, XSS, CSRF, auth bypass, secrets in code)
- Edge cases that aren't handled
- Error handling gaps
- Performance issues (N+1 queries, memory leaks, blocking calls)
- API contract violations
- Data validation gaps

Be thorough and adversarial. List every issue with severity [Critical/Bug/Warning].
Format: **[Severity]** file:line — description
${adv_memory:+
## Known Security Issues from Previous Reviews
These security issues have been found in past reviews. Check if any recur:
${adv_memory}
}
Diff:
$diff_content"

    local review_output
    review_output=$(claude --print "$prompt" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-adversarial.log" || true)
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-adversarial.log"

    echo "$review_output" > "$ARTIFACTS_DIR/adversarial-review.md"

    # Count issues by severity
    local critical_count bug_count
    critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
    bug_count="${bug_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Adversarial review: ${critical_count} critical, ${bug_count} bugs"
        return 1
    elif [[ "$bug_count" -gt 0 ]]; then
        warn "Adversarial review: ${bug_count} bugs found"
        return 1
    fi

    success "Adversarial review: clean"
    return 0
}

run_negative_prompting() {
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH}...HEAD" 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        info "No changed files to analyze"
        return 0
    fi

    # Read contents of changed files
    local file_contents=""
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            file_contents+="
--- $file ---
$(head -200 "$file" 2>/dev/null || true)
"
        fi
    done <<< "$changed_files"

    # Inject previous negative prompting findings from memory
    local neg_memory=""
    if type intelligence_search_memory &>/dev/null 2>&1; then
        neg_memory=$(intelligence_search_memory "negative prompting findings common concerns for: ${GOAL:-}" "${HOME}/.shipwright/memory" 5 2>/dev/null) || true
    fi

    local prompt="You are a pessimistic engineer who assumes everything will break.
Review these changes and answer:
1. What could go wrong in production?
2. What did the developer miss?
3. What's fragile and will break when requirements change?
4. What assumptions are being made that might not hold?
5. What happens under load/stress?
6. What happens with malicious input?
7. Are there any implicit dependencies that could break?
${neg_memory:+
## Known Concerns from Previous Reviews
These issues have been found in past reviews of this codebase. Check if any apply to the current changes:
${neg_memory}
}
Be specific. Reference actual code. Categorize each concern as [Critical/Concern/Minor].

Files changed: $changed_files

$file_contents"

    local review_output
    review_output=$(claude --print "$prompt" < /dev/null 2>"${ARTIFACTS_DIR}/.claude-tokens-negative.log" || true)
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-negative.log"

    echo "$review_output" > "$ARTIFACTS_DIR/negative-review.md"

    local critical_count
    critical_count=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
    critical_count="${critical_count:-0}"

    if [[ "$critical_count" -gt 0 ]]; then
        warn "Negative prompting: ${critical_count} critical concerns"
        return 1
    fi

    success "Negative prompting: no critical concerns"
    return 0
}

run_e2e_validation() {
    local test_cmd="${TEST_CMD}"
    if [[ -z "$test_cmd" ]]; then
        test_cmd=$(detect_test_cmd)
    fi

    if [[ -z "$test_cmd" ]]; then
        warn "No test command configured — skipping E2E validation"
        return 0
    fi

    info "Running E2E validation: $test_cmd"
    if bash -c "$test_cmd" > "$ARTIFACTS_DIR/e2e-validation.log" 2>&1; then
        success "E2E validation passed"
        return 0
    else
        error "E2E validation failed"
        return 1
    fi
}

run_dod_audit() {
    local dod_file="$PROJECT_ROOT/.claude/DEFINITION-OF-DONE.md"

    if [[ ! -f "$dod_file" ]]; then
        # Check for alternative locations
        for alt in "$PROJECT_ROOT/DEFINITION-OF-DONE.md" "$HOME/.shipwright/templates/definition-of-done.example.md"; do
            if [[ -f "$alt" ]]; then
                dod_file="$alt"
                break
            fi
        done
    fi

    if [[ ! -f "$dod_file" ]]; then
        info "No definition-of-done found — skipping DoD audit"
        return 0
    fi

    info "Auditing Definition of Done..."

    local total=0 passed=0 failed=0
    local audit_output="# DoD Audit Results\n\n"

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]]\] ]]; then
            total=$((total + 1))
            local item="${line#*] }"

            # Try to verify common items
            local item_passed=false
            case "$item" in
                *"tests pass"*|*"test pass"*)
                    if [[ -f "$ARTIFACTS_DIR/test-results.log" ]] && ! grep -qi "fail\|error" "$ARTIFACTS_DIR/test-results.log" 2>/dev/null; then
                        item_passed=true
                    fi
                    ;;
                *"lint"*|*"Lint"*)
                    if [[ -f "$ARTIFACTS_DIR/lint.log" ]] && ! grep -qi "error" "$ARTIFACTS_DIR/lint.log" 2>/dev/null; then
                        item_passed=true
                    fi
                    ;;
                *"console.log"*|*"print("*)
                    local debug_count
                    debug_count=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null | grep -c "^+.*console\.log\|^+.*print(" 2>/dev/null || true)
                    debug_count="${debug_count:-0}"
                    if [[ "$debug_count" -eq 0 ]]; then
                        item_passed=true
                    fi
                    ;;
                *"coverage"*)
                    item_passed=true  # Trust test stage coverage check
                    ;;
                *)
                    item_passed=true  # Default pass for items we can't auto-verify
                    ;;
            esac

            if $item_passed; then
                passed=$((passed + 1))
                audit_output+="- [x] $item\n"
            else
                failed=$((failed + 1))
                audit_output+="- [ ] $item ❌\n"
            fi
        fi
    done < "$dod_file"

    echo -e "$audit_output\n\n**Score: ${passed}/${total} passed**" > "$ARTIFACTS_DIR/dod-audit.md"

    if [[ "$failed" -gt 0 ]]; then
        warn "DoD audit: ${passed}/${total} passed, ${failed} failed"
        return 1
    fi

    success "DoD audit: ${passed}/${total} passed"
    return 0
}

# ─── Intelligent Pipeline Orchestration ──────────────────────────────────────
# AGI-like decision making: skip, classify, adapt, reassess, backtrack

# Global state for intelligence features
PIPELINE_BACKTRACK_COUNT="${PIPELINE_BACKTRACK_COUNT:-0}"
PIPELINE_MAX_BACKTRACKS=2
PIPELINE_ADAPTIVE_COMPLEXITY=""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Intelligent Stage Skipping
# Evaluates whether a stage should be skipped based on triage score, complexity,
# issue labels, and diff size. Called before each stage in run_pipeline().
# Returns 0 if the stage SHOULD be skipped, 1 if it should run.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_should_skip_stage() {
    local stage_id="$1"
    local reason=""

    # Never skip intake or build — they're always required
    case "$stage_id" in
        intake|build|test|pr|merge) return 1 ;;
    esac

    # ── Signal 1: Triage score (from intelligence analysis) ──
    local triage_score="${INTELLIGENCE_COMPLEXITY:-0}"
    # Convert: high triage score (simple issue) means skip more stages
    # INTELLIGENCE_COMPLEXITY is 1-10 (1=simple, 10=complex)
    # Score >= 70 in daemon means simple → complexity 1-3
    local complexity="${INTELLIGENCE_COMPLEXITY:-5}"

    # ── Signal 2: Issue labels ──
    local labels="${ISSUE_LABELS:-}"

    # Documentation issues: skip test, review, compound_quality
    if echo ",$labels," | grep -qiE ',documentation,|,docs,|,typo,'; then
        case "$stage_id" in
            test|review|compound_quality)
                reason="label:documentation"
                ;;
        esac
    fi

    # Hotfix issues: skip plan, design, compound_quality
    if echo ",$labels," | grep -qiE ',hotfix,|,urgent,|,p0,'; then
        case "$stage_id" in
            plan|design|compound_quality)
                reason="label:hotfix"
                ;;
        esac
    fi

    # ── Signal 3: Intelligence complexity ──
    if [[ -z "$reason" && "$complexity" -gt 0 ]]; then
        # Complexity 1-2: very simple → skip design, compound_quality, review
        if [[ "$complexity" -le 2 ]]; then
            case "$stage_id" in
                design|compound_quality|review)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        # Complexity 1-3: simple → skip design
        elif [[ "$complexity" -le 3 ]]; then
            case "$stage_id" in
                design)
                    reason="complexity:${complexity}/10"
                    ;;
            esac
        fi
    fi

    # ── Signal 4: Diff size (after build) ──
    if [[ -z "$reason" && "$stage_id" == "compound_quality" ]]; then
        local diff_lines=0
        local _skip_stat
        _skip_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
        if [[ -n "${_skip_stat:-}" ]]; then
            local _s_ins _s_del
            _s_ins=$(echo "$_skip_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
            _s_del=$(echo "$_skip_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
            diff_lines=$(( ${_s_ins:-0} + ${_s_del:-0} ))
        fi
        diff_lines="${diff_lines:-0}"
        if [[ "$diff_lines" -gt 0 && "$diff_lines" -lt 20 ]]; then
            reason="diff_size:${diff_lines}_lines"
        fi
    fi

    # ── Signal 5: Mid-pipeline reassessment override ──
    if [[ -z "$reason" && -f "$ARTIFACTS_DIR/reassessment.json" ]]; then
        local skip_stages
        skip_stages=$(jq -r '.skip_stages // [] | .[]' "$ARTIFACTS_DIR/reassessment.json" 2>/dev/null || true)
        if echo "$skip_stages" | grep -qx "$stage_id" 2>/dev/null; then
            reason="reassessment:simpler_than_expected"
        fi
    fi

    if [[ -n "$reason" ]]; then
        emit_event "intelligence.stage_skipped" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "reason=$reason" \
            "complexity=${complexity}" \
            "labels=${labels}"
        echo "$reason"
        return 0
    fi

    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Smart Finding Classification & Routing
# Parses compound quality findings and classifies each as:
#   architecture, security, correctness, style
# Returns JSON with classified findings and routing recommendations.
# ──────────────────────────────────────────────────────────────────────────────
classify_quality_findings() {
    local findings_dir="$ARTIFACTS_DIR"
    local result_file="$ARTIFACTS_DIR/classified-findings.json"

    # Initialize counters
    local arch_count=0 security_count=0 correctness_count=0 performance_count=0 testing_count=0 style_count=0

    # Start building JSON array
    local findings_json="[]"

    # ── Parse adversarial review ──
    if [[ -f "$findings_dir/adversarial-review.md" ]]; then
        local adv_content
        adv_content=$(cat "$findings_dir/adversarial-review.md" 2>/dev/null || true)

        # Architecture findings: dependency violations, layer breaches, circular refs
        local arch_findings
        arch_findings=$(echo "$adv_content" | grep -ciE 'architect|layer.*violation|circular.*depend|coupling|abstraction|design.*flaw|separation.*concern' 2>/dev/null || true)
        arch_count=$((arch_count + ${arch_findings:-0}))

        # Security findings
        local sec_findings
        sec_findings=$(echo "$adv_content" | grep -ciE 'security|vulnerab|injection|XSS|CSRF|auth.*bypass|privilege|sanitiz|escap' 2>/dev/null || true)
        security_count=$((security_count + ${sec_findings:-0}))

        # Correctness findings: bugs, logic errors, edge cases
        local corr_findings
        corr_findings=$(echo "$adv_content" | grep -ciE '\*\*\[?(Critical|Bug|Error|critical|high)\]?\*\*|race.*condition|null.*pointer|off.*by.*one|edge.*case|undefined.*behav' 2>/dev/null || true)
        correctness_count=$((correctness_count + ${corr_findings:-0}))

        # Performance findings
        local perf_findings
        perf_findings=$(echo "$adv_content" | grep -ciE 'latency|slow|memory leak|O\(n|N\+1|cache miss|performance|bottleneck|throughput' 2>/dev/null || true)
        performance_count=$((performance_count + ${perf_findings:-0}))

        # Testing findings
        local test_findings
        test_findings=$(echo "$adv_content" | grep -ciE 'untested|missing test|no coverage|flaky|test gap|test missing|coverage gap' 2>/dev/null || true)
        testing_count=$((testing_count + ${test_findings:-0}))

        # Style findings
        local style_findings
        style_findings=$(echo "$adv_content" | grep -ciE 'naming|convention|format|style|readabil|inconsisten|whitespace|comment' 2>/dev/null || true)
        style_count=$((style_count + ${style_findings:-0}))
    fi

    # ── Parse architecture validation ──
    if [[ -f "$findings_dir/compound-architecture-validation.json" ]]; then
        local arch_json_count
        arch_json_count=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$findings_dir/compound-architecture-validation.json" 2>/dev/null || echo "0")
        arch_count=$((arch_count + ${arch_json_count:-0}))
    fi

    # ── Parse security audit ──
    if [[ -f "$findings_dir/security-audit.log" ]]; then
        local sec_audit
        sec_audit=$(grep -ciE 'critical|high' "$findings_dir/security-audit.log" 2>/dev/null || true)
        security_count=$((security_count + ${sec_audit:-0}))
    fi

    # ── Parse negative review ──
    if [[ -f "$findings_dir/negative-review.md" ]]; then
        local neg_corr
        neg_corr=$(grep -ciE '\[Critical\]|\[High\]' "$findings_dir/negative-review.md" 2>/dev/null || true)
        correctness_count=$((correctness_count + ${neg_corr:-0}))
    fi

    # ── Determine routing ──
    # Priority order: security > architecture > correctness > performance > testing > style
    local route="correctness"  # default
    local needs_backtrack=false
    local priority_findings=""

    if [[ "$security_count" -gt 0 ]]; then
        route="security"
        priority_findings="security:${security_count}"
    fi

    if [[ "$arch_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" ]]; then
            route="architecture"
            needs_backtrack=true
        fi
        priority_findings="${priority_findings:+${priority_findings},}architecture:${arch_count}"
    fi

    if [[ "$correctness_count" -gt 0 ]]; then
        priority_findings="${priority_findings:+${priority_findings},}correctness:${correctness_count}"
    fi

    if [[ "$performance_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" && "$correctness_count" -eq 0 ]]; then
            route="performance"
        fi
        priority_findings="${priority_findings:+${priority_findings},}performance:${performance_count}"
    fi

    if [[ "$testing_count" -gt 0 ]]; then
        if [[ "$route" == "correctness" && "$correctness_count" -eq 0 && "$performance_count" -eq 0 ]]; then
            route="testing"
        fi
        priority_findings="${priority_findings:+${priority_findings},}testing:${testing_count}"
    fi

    # Style findings don't affect routing or count toward failure threshold
    local total_blocking=$((arch_count + security_count + correctness_count + performance_count + testing_count))

    # Write classified findings
    local tmp_findings
    tmp_findings="$(mktemp)"
    jq -n \
        --argjson arch "$arch_count" \
        --argjson security "$security_count" \
        --argjson correctness "$correctness_count" \
        --argjson performance "$performance_count" \
        --argjson testing "$testing_count" \
        --argjson style "$style_count" \
        --argjson total_blocking "$total_blocking" \
        --arg route "$route" \
        --argjson needs_backtrack "$needs_backtrack" \
        --arg priority "$priority_findings" \
        '{
            architecture: $arch,
            security: $security,
            correctness: $correctness,
            performance: $performance,
            testing: $testing,
            style: $style,
            total_blocking: $total_blocking,
            route: $route,
            needs_backtrack: $needs_backtrack,
            priority_findings: $priority
        }' > "$tmp_findings" 2>/dev/null && mv "$tmp_findings" "$result_file" || rm -f "$tmp_findings"

    emit_event "intelligence.findings_classified" \
        "issue=${ISSUE_NUMBER:-0}" \
        "architecture=$arch_count" \
        "security=$security_count" \
        "correctness=$correctness_count" \
        "performance=$performance_count" \
        "testing=$testing_count" \
        "style=$style_count" \
        "route=$route" \
        "needs_backtrack=$needs_backtrack"

    echo "$route"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Adaptive Cycle Limits
# Replaces hardcoded max_cycles with convergence-driven limits.
# Takes the base limit, returns an adjusted limit based on:
#   - Learned iteration model
#   - Convergence/divergence signals
#   - Budget constraints
#   - Hard ceiling (2x template max)
# ──────────────────────────────────────────────────────────────────────────────
pipeline_adaptive_cycles() {
    local base_limit="$1"
    local context="${2:-compound_quality}"  # compound_quality or build_test
    local current_issue_count="${3:-0}"
    local prev_issue_count="${4:--1}"

    local adjusted="$base_limit"
    local hard_ceiling=$((base_limit * 2))

    # ── Learned iteration model ──
    local model_file="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$model_file" ]]; then
        local learned
        learned=$(jq -r --arg ctx "$context" '.[$ctx].recommended_cycles // 0' "$model_file" 2>/dev/null || echo "0")
        if [[ "$learned" -gt 0 && "$learned" -le "$hard_ceiling" ]]; then
            adjusted="$learned"
        fi
    fi

    # ── Convergence acceleration ──
    # If issue count drops >50% per cycle, extend limit by 1 (we're making progress)
    if [[ "$prev_issue_count" -gt 0 && "$current_issue_count" -ge 0 ]]; then
        local half_prev=$((prev_issue_count / 2))
        if [[ "$current_issue_count" -le "$half_prev" && "$current_issue_count" -gt 0 ]]; then
            # Rapid convergence — extend by 1
            local new_limit=$((adjusted + 1))
            if [[ "$new_limit" -le "$hard_ceiling" ]]; then
                adjusted="$new_limit"
                emit_event "intelligence.convergence_acceleration" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi

        # ── Divergence detection ──
        # If issue count increases, reduce remaining cycles
        if [[ "$current_issue_count" -gt "$prev_issue_count" ]]; then
            local reduced=$((adjusted - 1))
            if [[ "$reduced" -ge 1 ]]; then
                adjusted="$reduced"
                emit_event "intelligence.divergence_detected" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "context=$context" \
                    "prev_issues=$prev_issue_count" \
                    "current_issues=$current_issue_count" \
                    "new_limit=$adjusted"
            fi
        fi
    fi

    # ── Budget gate ──
    if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        local budget_rc=0
        bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
        if [[ "$budget_rc" -eq 2 ]]; then
            # Budget exhausted — cap at current cycle
            adjusted=0
            emit_event "intelligence.budget_cap" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=$context"
        fi
    fi

    # ── Enforce hard ceiling ──
    if [[ "$adjusted" -gt "$hard_ceiling" ]]; then
        adjusted="$hard_ceiling"
    fi

    echo "$adjusted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Intelligent Audit Selection
# AI-driven audit selection — all audits enabled, intensity varies.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_select_audits() {
    local audit_intensity
    audit_intensity=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.audit_intensity) // "auto"' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$audit_intensity" || "$audit_intensity" == "null" ]] && audit_intensity="auto"

    # Short-circuit for explicit overrides
    case "$audit_intensity" in
        off)
            echo '{"adversarial":"off","architecture":"off","simulation":"off","security":"off","dod":"off"}'
            return 0
            ;;
        full|lightweight)
            jq -n --arg i "$audit_intensity" \
                '{adversarial:$i,architecture:$i,simulation:$i,security:$i,dod:$i}'
            return 0
            ;;
    esac

    # ── Auto mode: data-driven intensity ──
    local default_intensity="targeted"
    local security_intensity="targeted"

    # Read last 5 quality scores for this repo
    local quality_scores_file="${HOME}/.shipwright/optimization/quality-scores.jsonl"
    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true
    if [[ -f "$quality_scores_file" ]]; then
        local recent_scores
        recent_scores=$(grep "\"repo\":\"${repo_name}\"" "$quality_scores_file" 2>/dev/null | tail -5) || true
        if [[ -n "$recent_scores" ]]; then
            # Check for critical findings in recent history
            local has_critical
            has_critical=$(echo "$recent_scores" | jq -s '[.[].findings.critical // 0] | add' 2>/dev/null || echo "0")
            has_critical="${has_critical:-0}"
            if [[ "$has_critical" -gt 0 ]]; then
                security_intensity="full"
            fi

            # Compute average quality score
            local avg_score
            avg_score=$(echo "$recent_scores" | jq -s 'if length > 0 then ([.[].quality_score] | add / length | floor) else 70 end' 2>/dev/null || echo "70")
            avg_score="${avg_score:-70}"

            if [[ "$avg_score" -lt 60 ]]; then
                default_intensity="full"
                security_intensity="full"
            elif [[ "$avg_score" -gt 80 ]]; then
                default_intensity="lightweight"
                [[ "$security_intensity" != "full" ]] && security_intensity="lightweight"
            fi
        fi
    fi

    # Intelligence cache: upgrade targeted→full for complex changes
    local intel_cache="${PROJECT_ROOT}/.claude/intelligence-cache.json"
    if [[ -f "$intel_cache" && "$default_intensity" == "targeted" ]]; then
        local complexity
        complexity=$(jq -r '.complexity // "medium"' "$intel_cache" 2>/dev/null || echo "medium")
        if [[ "$complexity" == "high" || "$complexity" == "very_high" ]]; then
            default_intensity="full"
            security_intensity="full"
        fi
    fi

    emit_event "pipeline.audit_selection" \
        "issue=${ISSUE_NUMBER:-0}" \
        "default_intensity=$default_intensity" \
        "security_intensity=$security_intensity" \
        "repo=$repo_name"

    jq -n \
        --arg adv "$default_intensity" \
        --arg arch "$default_intensity" \
        --arg sim "$default_intensity" \
        --arg sec "$security_intensity" \
        --arg dod "$default_intensity" \
        '{adversarial:$adv,architecture:$arch,simulation:$sim,security:$sec,dod:$dod}'
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Definition of Done Verification
# Strict DoD enforcement after compound quality completes.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_verify_dod() {
    local artifacts_dir="${1:-$ARTIFACTS_DIR}"
    local checks_total=0 checks_passed=0
    local results=""

    # 1. Test coverage: verify changed source files have test counterparts
    local changed_files
    changed_files=$(git diff --name-only "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
    local missing_tests=""
    local files_checked=0

    if [[ -n "$changed_files" ]]; then
        while IFS= read -r src_file; do
            [[ -z "$src_file" ]] && continue
            # Only check source code files
            case "$src_file" in
                *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.sh)
                    # Skip test files themselves and config files
                    case "$src_file" in
                        *test*|*spec*|*__tests__*|*.config.*|*.d.ts) continue ;;
                    esac
                    files_checked=$((files_checked + 1))
                    checks_total=$((checks_total + 1))
                    # Check for corresponding test file
                    local base_name dir_name ext
                    base_name=$(basename "$src_file")
                    dir_name=$(dirname "$src_file")
                    ext="${base_name##*.}"
                    local stem="${base_name%.*}"
                    local test_found=false
                    # Common test file patterns
                    for pattern in \
                        "${dir_name}/${stem}.test.${ext}" \
                        "${dir_name}/${stem}.spec.${ext}" \
                        "${dir_name}/__tests__/${stem}.test.${ext}" \
                        "${dir_name}/${stem}-test.${ext}" \
                        "${dir_name}/test_${stem}.${ext}" \
                        "${dir_name}/${stem}_test.${ext}"; do
                        if [[ -f "$pattern" ]]; then
                            test_found=true
                            break
                        fi
                    done
                    if $test_found; then
                        checks_passed=$((checks_passed + 1))
                    else
                        missing_tests="${missing_tests}${src_file}\n"
                    fi
                    ;;
            esac
        done <<EOF
$changed_files
EOF
    fi

    # 2. Test-added verification: if significant logic added, ensure tests were also added
    local logic_lines=0 test_lines=0
    if [[ -n "$changed_files" ]]; then
        local full_diff
        full_diff=$(git diff "${BASE_BRANCH:-main}...HEAD" 2>/dev/null || true)
        if [[ -n "$full_diff" ]]; then
            # Count added lines matching source patterns (rough heuristic)
            logic_lines=$(echo "$full_diff" | grep -cE '^\+.*(function |class |if |for |while |return |export )' 2>/dev/null || true)
            logic_lines="${logic_lines:-0}"
            # Count added lines in test files
            test_lines=$(echo "$full_diff" | grep -cE '^\+.*(it\(|test\(|describe\(|expect\(|assert|def test_|func Test)' 2>/dev/null || true)
            test_lines="${test_lines:-0}"
        fi
    fi
    checks_total=$((checks_total + 1))
    local test_ratio_passed=true
    if [[ "$logic_lines" -gt 20 && "$test_lines" -eq 0 ]]; then
        test_ratio_passed=false
        warn "DoD verification: ${logic_lines} logic lines added but no test lines detected"
    else
        checks_passed=$((checks_passed + 1))
    fi

    # 3. Behavioral verification: check DoD audit artifacts for evidence
    local dod_audit_file="$artifacts_dir/dod-audit.md"
    local dod_verified=0 dod_total_items=0
    if [[ -f "$dod_audit_file" ]]; then
        # Count items marked as passing
        dod_total_items=$(grep -cE '^\s*-\s*\[x\]' "$dod_audit_file" 2>/dev/null || true)
        dod_total_items="${dod_total_items:-0}"
        local dod_failing
        dod_failing=$(grep -cE '^\s*-\s*\[\s\]' "$dod_audit_file" 2>/dev/null || true)
        dod_failing="${dod_failing:-0}"
        dod_verified=$dod_total_items
        checks_total=$((checks_total + dod_total_items + ${dod_failing:-0}))
        checks_passed=$((checks_passed + dod_total_items))
    fi

    # Compute pass rate
    local pass_rate=100
    if [[ "$checks_total" -gt 0 ]]; then
        pass_rate=$(( (checks_passed * 100) / checks_total ))
    fi

    # Write results
    local tmp_result
    tmp_result=$(mktemp)
    jq -n \
        --argjson checks_total "$checks_total" \
        --argjson checks_passed "$checks_passed" \
        --argjson pass_rate "$pass_rate" \
        --argjson files_checked "$files_checked" \
        --arg missing_tests "$(echo -e "$missing_tests" | head -20)" \
        --argjson logic_lines "$logic_lines" \
        --argjson test_lines "$test_lines" \
        --argjson test_ratio_passed "$test_ratio_passed" \
        --argjson dod_verified "$dod_verified" \
        '{
            checks_total: $checks_total,
            checks_passed: $checks_passed,
            pass_rate: $pass_rate,
            files_checked: $files_checked,
            missing_tests: ($missing_tests | split("\n") | map(select(. != ""))),
            logic_lines: $logic_lines,
            test_lines: $test_lines,
            test_ratio_passed: $test_ratio_passed,
            dod_verified: $dod_verified
        }' > "$tmp_result" 2>/dev/null
    mv "$tmp_result" "$artifacts_dir/dod-verification.json"

    emit_event "pipeline.dod_verification" \
        "issue=${ISSUE_NUMBER:-0}" \
        "checks_total=$checks_total" \
        "checks_passed=$checks_passed" \
        "pass_rate=$pass_rate"

    # Fail if pass rate < 70%
    if [[ "$pass_rate" -lt 70 ]]; then
        warn "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
        return 1
    fi

    success "DoD verification: ${pass_rate}% pass rate (${checks_passed}/${checks_total} checks)"
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Source Code Security Scan
# Grep-based vulnerability pattern matching on changed files.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_security_source_scan() {
    local base_branch="${1:-${BASE_BRANCH:-main}}"
    local findings="[]"
    local finding_count=0

    local changed_files
    changed_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || true)
    [[ -z "$changed_files" ]] && { echo "[]"; return 0; }

    local tmp_findings
    tmp_findings=$(mktemp)
    echo "[]" > "$tmp_findings"

    while IFS= read -r file; do
        [[ -z "$file" || ! -f "$file" ]] && continue
        # Only scan code files
        case "$file" in
            *.ts|*.js|*.tsx|*.jsx|*.py|*.go|*.rs|*.java|*.rb|*.php|*.sh) ;;
            *) continue ;;
        esac

        # SQL injection patterns
        local sql_matches
        sql_matches=$(grep -nE '(query|execute|sql)\s*\(?\s*[`"'"'"']\s*.*\$\{|\.query\s*\(\s*[`"'"'"'].*\+' "$file" 2>/dev/null || true)
        if [[ -n "$sql_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "sql_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential SQL injection via string concatenation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SQLEOF
$sql_matches
SQLEOF
        fi

        # XSS patterns
        local xss_matches
        xss_matches=$(grep -nE 'innerHTML\s*=|document\.write\s*\(|dangerouslySetInnerHTML' "$file" 2>/dev/null || true)
        if [[ -n "$xss_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "xss" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential XSS via unsafe DOM manipulation"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<XSSEOF
$xss_matches
XSSEOF
        fi

        # Command injection patterns
        local cmd_matches
        cmd_matches=$(grep -nE 'eval\s*\(|child_process|os\.system\s*\(|subprocess\.(call|run|Popen)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$cmd_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "command_injection" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential command injection via unsafe execution"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CMDEOF
$cmd_matches
CMDEOF
        fi

        # Hardcoded secrets patterns
        local secret_matches
        secret_matches=$(grep -nEi '(password|api_key|secret|token)\s*=\s*['"'"'"][A-Za-z0-9+/=]{8,}['"'"'"]' "$file" 2>/dev/null || true)
        if [[ -n "$secret_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "hardcoded_secret" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"critical","description":"Potential hardcoded secret or credential"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<SECEOF
$secret_matches
SECEOF
        fi

        # Insecure crypto patterns
        local crypto_matches
        crypto_matches=$(grep -nE '(md5|MD5|sha1|SHA1)\s*\(' "$file" 2>/dev/null || true)
        if [[ -n "$crypto_matches" ]]; then
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                local line_num="${match%%:*}"
                finding_count=$((finding_count + 1))
                local current
                current=$(cat "$tmp_findings")
                echo "$current" | jq --arg f "$file" --arg l "$line_num" --arg p "insecure_crypto" \
                    '. + [{"file":$f,"line":($l|tonumber),"pattern":$p,"severity":"major","description":"Weak cryptographic function (consider SHA-256+)"}]' \
                    > "$tmp_findings" 2>/dev/null || true
            done <<CRYEOF
$crypto_matches
CRYEOF
        fi
    done <<FILESEOF
$changed_files
FILESEOF

    # Write to artifacts and output
    findings=$(cat "$tmp_findings")
    rm -f "$tmp_findings"

    if [[ -n "${ARTIFACTS_DIR:-}" ]]; then
        local tmp_scan
        tmp_scan=$(mktemp)
        echo "$findings" > "$tmp_scan"
        mv "$tmp_scan" "$ARTIFACTS_DIR/security-source-scan.json"
    fi

    emit_event "pipeline.security_source_scan" \
        "issue=${ISSUE_NUMBER:-0}" \
        "findings=$finding_count"

    echo "$finding_count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Quality Score Recording
# Writes quality scores to JSONL for learning.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_record_quality_score() {
    local quality_score="${1:-0}"
    local critical="${2:-0}"
    local major="${3:-0}"
    local minor="${4:-0}"
    local dod_pass_rate="${5:-0}"
    local audits_run="${6:-}"

    local scores_dir="${HOME}/.shipwright/optimization"
    local scores_file="${scores_dir}/quality-scores.jsonl"
    mkdir -p "$scores_dir"

    local repo_name
    repo_name=$(basename "${PROJECT_ROOT:-.}") || true

    local tmp_score
    tmp_score=$(mktemp)
    jq -n \
        --arg repo "$repo_name" \
        --arg issue "${ISSUE_NUMBER:-0}" \
        --arg ts "$(now_iso)" \
        --argjson score "$quality_score" \
        --argjson critical "$critical" \
        --argjson major "$major" \
        --argjson minor "$minor" \
        --argjson dod "$dod_pass_rate" \
        --arg template "${PIPELINE_NAME:-standard}" \
        --arg audits "$audits_run" \
        '{
            repo: $repo,
            issue: ($issue | tonumber),
            timestamp: $ts,
            quality_score: $score,
            findings: {critical: $critical, major: $major, minor: $minor},
            dod_pass_rate: $dod,
            template: $template,
            audits_run: ($audits | split(",") | map(select(. != "")))
        }' > "$tmp_score" 2>/dev/null

    cat "$tmp_score" >> "$scores_file"
    rm -f "$tmp_score"

    emit_event "pipeline.quality_score_recorded" \
        "issue=${ISSUE_NUMBER:-0}" \
        "quality_score=$quality_score" \
        "critical=$critical" \
        "major=$major" \
        "minor=$minor"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Mid-Pipeline Complexity Re-evaluation
# After build+test completes, compares actual effort to initial estimate.
# Updates skip recommendations and model routing for remaining stages.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_reassess_complexity() {
    local initial_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
    local reassessment_file="$ARTIFACTS_DIR/reassessment.json"

    # ── Gather actual metrics ──
    local files_changed=0 lines_changed=0 first_try_pass=false self_heal_cycles=0

    files_changed=$(git diff "${BASE_BRANCH:-main}...HEAD" --name-only 2>/dev/null | wc -l | tr -d ' ') || files_changed=0
    files_changed="${files_changed:-0}"

    # Count lines changed (insertions + deletions) without pipefail issues
    lines_changed=0
    local _diff_stat
    _diff_stat=$(git diff "${BASE_BRANCH:-main}...HEAD" --stat 2>/dev/null | tail -1) || true
    if [[ -n "${_diff_stat:-}" ]]; then
        local _ins _del
        _ins=$(echo "$_diff_stat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+') || true
        _del=$(echo "$_diff_stat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+') || true
        lines_changed=$(( ${_ins:-0} + ${_del:-0} ))
    fi

    self_heal_cycles="${SELF_HEAL_COUNT:-0}"
    if [[ "$self_heal_cycles" -eq 0 ]]; then
        first_try_pass=true
    fi

    # ── Compare to expectations ──
    local actual_complexity="$initial_complexity"
    local assessment="as_expected"
    local skip_stages="[]"

    # Simpler than expected: small diff, tests passed first try
    if [[ "$lines_changed" -lt 50 && "$first_try_pass" == "true" && "$files_changed" -lt 5 ]]; then
        actual_complexity=$((initial_complexity > 2 ? initial_complexity - 2 : 1))
        assessment="simpler_than_expected"
        # Mark compound_quality as skippable, simplify review
        skip_stages='["compound_quality"]'
    # Much simpler
    elif [[ "$lines_changed" -lt 20 && "$first_try_pass" == "true" && "$files_changed" -lt 3 ]]; then
        actual_complexity=1
        assessment="much_simpler"
        skip_stages='["compound_quality","review"]'
    # Harder than expected: large diff, multiple self-heal cycles
    elif [[ "$lines_changed" -gt 500 || "$self_heal_cycles" -gt 2 ]]; then
        actual_complexity=$((initial_complexity < 9 ? initial_complexity + 2 : 10))
        assessment="harder_than_expected"
        # Ensure compound_quality runs, possibly upgrade model
        skip_stages='[]'
    # Much harder
    elif [[ "$lines_changed" -gt 1000 || "$self_heal_cycles" -gt 4 ]]; then
        actual_complexity=10
        assessment="much_harder"
        skip_stages='[]'
    fi

    # ── Write reassessment ──
    local tmp_reassess
    tmp_reassess="$(mktemp)"
    jq -n \
        --argjson initial "$initial_complexity" \
        --argjson actual "$actual_complexity" \
        --arg assessment "$assessment" \
        --argjson files_changed "$files_changed" \
        --argjson lines_changed "$lines_changed" \
        --argjson self_heal_cycles "$self_heal_cycles" \
        --argjson first_try "$first_try_pass" \
        --argjson skip_stages "$skip_stages" \
        '{
            initial_complexity: $initial,
            actual_complexity: $actual,
            assessment: $assessment,
            files_changed: $files_changed,
            lines_changed: $lines_changed,
            self_heal_cycles: $self_heal_cycles,
            first_try_pass: $first_try,
            skip_stages: $skip_stages
        }' > "$tmp_reassess" 2>/dev/null && mv "$tmp_reassess" "$reassessment_file" || rm -f "$tmp_reassess"

    # Update global complexity for downstream stages
    PIPELINE_ADAPTIVE_COMPLEXITY="$actual_complexity"

    emit_event "intelligence.reassessment" \
        "issue=${ISSUE_NUMBER:-0}" \
        "initial=$initial_complexity" \
        "actual=$actual_complexity" \
        "assessment=$assessment" \
        "files=$files_changed" \
        "lines=$lines_changed" \
        "self_heals=$self_heal_cycles"

    # ── Store for learning ──
    local learning_file="${HOME}/.shipwright/optimization/complexity-actuals.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization" 2>/dev/null || true
    echo "{\"issue\":\"${ISSUE_NUMBER:-0}\",\"initial\":$initial_complexity,\"actual\":$actual_complexity,\"files\":$files_changed,\"lines\":$lines_changed,\"ts\":\"$(now_iso)\"}" \
        >> "$learning_file" 2>/dev/null || true

    echo "$assessment"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Backtracking Support
# When compound_quality detects architecture-level problems, backtracks to
# the design stage instead of just feeding findings to the build loop.
# Limited to 1 backtrack per pipeline run to prevent infinite loops.
# ──────────────────────────────────────────────────────────────────────────────
pipeline_backtrack_to_stage() {
    local target_stage="$1"
    local reason="${2:-architecture_violation}"

    # Prevent infinite backtracking
    if [[ "$PIPELINE_BACKTRACK_COUNT" -ge "$PIPELINE_MAX_BACKTRACKS" ]]; then
        warn "Max backtracks ($PIPELINE_MAX_BACKTRACKS) reached — cannot backtrack to $target_stage"
        emit_event "intelligence.backtrack_blocked" \
            "issue=${ISSUE_NUMBER:-0}" \
            "target=$target_stage" \
            "reason=max_backtracks_reached" \
            "count=$PIPELINE_BACKTRACK_COUNT"
        return 1
    fi

    PIPELINE_BACKTRACK_COUNT=$((PIPELINE_BACKTRACK_COUNT + 1))

    info "Backtracking to ${BOLD}${target_stage}${RESET} stage (reason: ${reason})"

    emit_event "intelligence.backtrack" \
        "issue=${ISSUE_NUMBER:-0}" \
        "target=$target_stage" \
        "reason=$reason"

    # Gather architecture context from findings
    local arch_context=""
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        arch_context=$(jq -r '[.[] | select(.severity == "critical" or .severity == "high") | .message // .description // ""] | join("\n")' \
            "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || true)
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
        local arch_lines
        arch_lines=$(grep -iE 'architect|layer.*violation|circular.*depend|coupling|design.*flaw' \
            "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
        if [[ -n "$arch_lines" ]]; then
            arch_context="${arch_context}
${arch_lines}"
        fi
    fi

    # Reset stages from target onward
    set_stage_status "$target_stage" "pending"
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"

    # Augment goal with architecture context for re-run
    local original_goal="$GOAL"
    if [[ -n "$arch_context" ]]; then
        GOAL="$GOAL

IMPORTANT — Architecture violations were detected during quality review. Redesign to fix:
$arch_context

Update the design to address these violations, then rebuild."
    fi

    # Re-run design stage
    info "Re-running ${BOLD}${target_stage}${RESET} with architecture context..."
    if "stage_${target_stage}" 2>/dev/null; then
        mark_stage_complete "$target_stage"
        success "Backtrack: ${target_stage} re-run complete"
    else
        GOAL="$original_goal"
        error "Backtrack: ${target_stage} re-run failed"
        return 1
    fi

    # Re-run build+test
    info "Re-running build→test after backtracked ${target_stage}..."
    if self_healing_build_test; then
        success "Backtrack: build→test passed after ${target_stage} redesign"
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        error "Backtrack: build→test failed after ${target_stage} redesign"
        return 1
    fi
}

compound_rebuild_with_feedback() {
    local feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

    # ── Intelligence: classify findings and determine routing ──
    local route="correctness"
    route=$(classify_quality_findings 2>/dev/null) || route="correctness"

    # ── Build structured findings JSON alongside markdown ──
    local structured_findings="[]"
    local s_total_critical=0 s_total_major=0 s_total_minor=0

    if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
        s_total_critical=$(jq -r '.security // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_major=$(jq -r '.correctness // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
        s_total_minor=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
    fi

    local tmp_qf
    tmp_qf="$(mktemp)"
    jq -n \
        --arg route "$route" \
        --argjson total_critical "$s_total_critical" \
        --argjson total_major "$s_total_major" \
        --argjson total_minor "$s_total_minor" \
        '{route: $route, total_critical: $total_critical, total_major: $total_major, total_minor: $total_minor}' \
        > "$tmp_qf" 2>/dev/null && mv "$tmp_qf" "$ARTIFACTS_DIR/quality-findings.json" || rm -f "$tmp_qf"

    # ── Architecture route: backtrack to design instead of rebuild ──
    if [[ "$route" == "architecture" ]]; then
        info "Architecture-level findings detected — attempting backtrack to design"
        if pipeline_backtrack_to_stage "design" "architecture_violation" 2>/dev/null; then
            return 0
        fi
        # Backtrack failed or already used — fall through to standard rebuild
        warn "Backtrack unavailable — falling through to standard rebuild"
    fi

    # Collect all findings (prioritized by classification)
    {
        echo "# Quality Feedback — Issues to Fix"
        echo ""

        # Security findings first (highest priority)
        if [[ "$route" == "security" || -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
            echo "## 🔴 PRIORITY: Security Findings (fix these first)"
            cat "$ARTIFACTS_DIR/security-audit.log"
            echo ""
            echo "Security issues MUST be resolved before any other changes."
            echo ""
        fi

        # Correctness findings
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            echo "## Adversarial Review Findings"
            cat "$ARTIFACTS_DIR/adversarial-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            echo "## Negative Prompting Concerns"
            cat "$ARTIFACTS_DIR/negative-review.md"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/dod-audit.md" ]]; then
            echo "## DoD Audit Failures"
            grep "❌" "$ARTIFACTS_DIR/dod-audit.md" 2>/dev/null || true
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/api-compat.log" ]] && grep -qi 'BREAKING' "$ARTIFACTS_DIR/api-compat.log" 2>/dev/null; then
            echo "## API Breaking Changes"
            cat "$ARTIFACTS_DIR/api-compat.log"
            echo ""
        fi

        # Style findings last (deprioritized, informational)
        if [[ -f "$ARTIFACTS_DIR/classified-findings.json" ]]; then
            local style_count
            style_count=$(jq -r '.style // 0' "$ARTIFACTS_DIR/classified-findings.json" 2>/dev/null || echo "0")
            if [[ "$style_count" -gt 0 ]]; then
                echo "## Style Notes (non-blocking, address if time permits)"
                echo "${style_count} style suggestions found. These do not block the build."
                echo ""
            fi
        fi
    } > "$feedback_file"

    # Validate feedback file has actual content
    if [[ ! -s "$feedback_file" ]]; then
        warn "No quality feedback collected — skipping rebuild"
        return 1
    fi

    # Reset build/test stages
    set_stage_status "build" "pending"
    set_stage_status "test" "pending"
    set_stage_status "review" "pending"

    # Augment GOAL with quality feedback (route-specific instructions)
    local original_goal="$GOAL"
    local feedback_content
    feedback_content=$(cat "$feedback_file")

    local route_instruction=""
    case "$route" in
        security)
            route_instruction="SECURITY PRIORITY: Fix all security vulnerabilities FIRST, then address other issues. Security issues are BLOCKING."
            ;;
        performance)
            route_instruction="PERFORMANCE PRIORITY: Address performance regressions and optimizations. Check for N+1 queries, memory leaks, and algorithmic complexity."
            ;;
        testing)
            route_instruction="TESTING PRIORITY: Add missing test coverage and fix flaky tests before addressing other issues."
            ;;
        correctness)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
        architecture)
            route_instruction="ARCHITECTURE: Fix structural issues. Check dependency direction, layer boundaries, and separation of concerns."
            ;;
        *)
            route_instruction="Fix every issue listed above while keeping all existing functionality working."
            ;;
    esac

    GOAL="$GOAL

IMPORTANT — Compound quality review found issues (route: ${route}). Fix ALL of these:
$feedback_content

${route_instruction}"

    # Re-run self-healing build→test
    info "Rebuilding with quality feedback (route: ${route})..."
    if self_healing_build_test; then
        GOAL="$original_goal"
        return 0
    else
        GOAL="$original_goal"
        return 1
    fi
}

stage_compound_quality() {
    CURRENT_STAGE_ID="compound_quality"

    # Read config
    local max_cycles adversarial_enabled negative_enabled e2e_enabled dod_enabled strict_quality
    max_cycles=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.max_cycles) // 3' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_cycles" || "$max_cycles" == "null" ]] && max_cycles=3
    adversarial_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.adversarial) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    negative_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.negative) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    e2e_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.e2e) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    dod_enabled=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.dod_audit) // true' "$PIPELINE_CONFIG" 2>/dev/null) || true
    strict_quality=$(jq -r --arg id "compound_quality" '(.stages[] | select(.id == $id) | .config.strict_quality) // false' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$strict_quality" || "$strict_quality" == "null" ]] && strict_quality="false"

    # Intelligent audit selection
    local audit_plan='{"adversarial":"targeted","architecture":"targeted","simulation":"targeted","security":"targeted","dod":"targeted"}'
    if type pipeline_select_audits &>/dev/null 2>&1; then
        local _selected
        _selected=$(pipeline_select_audits 2>/dev/null) || true
        if [[ -n "$_selected" && "$_selected" != "null" ]]; then
            audit_plan="$_selected"
            info "Audit plan: $(echo "$audit_plan" | jq -c '.' 2>/dev/null || echo "$audit_plan")"
        fi
    fi

    # Track findings for quality score
    local total_critical=0 total_major=0 total_minor=0
    local audits_run_list=""

    # Vitals-driven adaptive cycle limit (preferred)
    local base_max_cycles="$max_cycles"
    if type pipeline_adaptive_limit &>/dev/null 2>&1; then
        local _cq_vitals=""
        if type pipeline_compute_vitals &>/dev/null 2>&1; then
            _cq_vitals=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_cq_limit
        vitals_cq_limit=$(pipeline_adaptive_limit "compound_quality" "$_cq_vitals" 2>/dev/null) || true
        if [[ -n "$vitals_cq_limit" && "$vitals_cq_limit" =~ ^[0-9]+$ && "$vitals_cq_limit" -gt 0 ]]; then
            max_cycles="$vitals_cq_limit"
            if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                info "Vitals-driven cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
            fi
        fi
    else
        # Fallback: adaptive cycle limits from optimization data
        local _cq_iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_cq_iter_model" ]]; then
            local adaptive_limit
            adaptive_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_limit" && "$adaptive_limit" =~ ^[0-9]+$ && "$adaptive_limit" -gt 0 ]]; then
                max_cycles="$adaptive_limit"
                if [[ "$max_cycles" != "$base_max_cycles" ]]; then
                    info "Adaptive cycles: ${base_max_cycles} → ${max_cycles} (compound_quality)"
                fi
            fi
        fi
    fi

    # Convergence tracking
    local prev_issue_count=-1

    local cycle=0
    while [[ "$cycle" -lt "$max_cycles" ]]; do
        cycle=$((cycle + 1))
        local all_passed=true

        echo ""
        echo -e "${PURPLE}${BOLD}━━━ Compound Quality — Cycle ${cycle}/${max_cycles} ━━━${RESET}"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "🔬 **Compound quality** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
        fi

        # 1. Adversarial Review
        local _adv_intensity
        _adv_intensity=$(echo "$audit_plan" | jq -r '.adversarial // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$adversarial_enabled" == "true" && "$_adv_intensity" != "off" ]]; then
            echo ""
            info "Running adversarial review (${_adv_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}adversarial"
            if ! run_adversarial_review; then
                all_passed=false
            fi
        fi

        # 2. Negative Prompting
        if [[ "$negative_enabled" == "true" ]]; then
            echo ""
            info "Running negative prompting..."
            if ! run_negative_prompting; then
                all_passed=false
            fi
        fi

        # 3. Developer Simulation (intelligence module)
        if type simulation_review &>/dev/null 2>&1; then
            local sim_enabled
            sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$sim_enabled" != "true" && -f "$daemon_cfg" ]]; then
                sim_enabled=$(jq -r '.intelligence.simulation_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$sim_enabled" == "true" ]]; then
                echo ""
                info "Running developer simulation review..."
                local sim_diff
                sim_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$sim_diff" ]]; then
                    local sim_result
                    sim_result=$(simulation_review "$sim_diff" "${GOAL:-}" 2>/dev/null || echo "[]")
                    if [[ -n "$sim_result" && "$sim_result" != "[]" && "$sim_result" != *'"error"'* ]]; then
                        echo "$sim_result" > "$ARTIFACTS_DIR/compound-simulation-review.json"
                        local sim_critical
                        sim_critical=$(echo "$sim_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local sim_total
                        sim_total=$(echo "$sim_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$sim_critical" -gt 0 ]]; then
                            warn "Developer simulation: ${sim_critical} critical/high concerns (${sim_total} total)"
                            all_passed=false
                        else
                            success "Developer simulation: ${sim_total} concerns (none critical/high)"
                        fi
                        emit_event "compound.simulation" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$sim_total" \
                            "critical=$sim_critical"
                    else
                        success "Developer simulation: no concerns"
                    fi
                fi
            fi
        fi

        # 4. Architecture Enforcer (intelligence module)
        if type architecture_validate_changes &>/dev/null 2>&1; then
            local arch_enabled
            arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$PIPELINE_CONFIG" 2>/dev/null || echo "false")
            local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
            if [[ "$arch_enabled" != "true" && -f "$daemon_cfg" ]]; then
                arch_enabled=$(jq -r '.intelligence.architecture_enabled // false' "$daemon_cfg" 2>/dev/null || echo "false")
            fi
            if [[ "$arch_enabled" == "true" ]]; then
                echo ""
                info "Running architecture validation..."
                local arch_diff
                arch_diff=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || true)
                if [[ -n "$arch_diff" ]]; then
                    local arch_result
                    arch_result=$(architecture_validate_changes "$arch_diff" "" 2>/dev/null || echo "[]")
                    if [[ -n "$arch_result" && "$arch_result" != "[]" && "$arch_result" != *'"error"'* ]]; then
                        echo "$arch_result" > "$ARTIFACTS_DIR/compound-architecture-validation.json"
                        local arch_violations
                        arch_violations=$(echo "$arch_result" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' 2>/dev/null || echo "0")
                        local arch_total
                        arch_total=$(echo "$arch_result" | jq 'length' 2>/dev/null || echo "0")
                        if [[ "$arch_violations" -gt 0 ]]; then
                            warn "Architecture validation: ${arch_violations} critical/high violations (${arch_total} total)"
                            all_passed=false
                        else
                            success "Architecture validation: ${arch_total} violations (none critical/high)"
                        fi
                        emit_event "compound.architecture" \
                            "issue=${ISSUE_NUMBER:-0}" \
                            "cycle=$cycle" \
                            "total=$arch_total" \
                            "violations=$arch_violations"
                    else
                        success "Architecture validation: no violations"
                    fi
                fi
            fi
        fi

        # 5. E2E Validation
        if [[ "$e2e_enabled" == "true" ]]; then
            echo ""
            info "Running E2E validation..."
            if ! run_e2e_validation; then
                all_passed=false
            fi
        fi

        # 6. DoD Audit
        local _dod_intensity
        _dod_intensity=$(echo "$audit_plan" | jq -r '.dod // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$dod_enabled" == "true" && "$_dod_intensity" != "off" ]]; then
            echo ""
            info "Running Definition of Done audit (${_dod_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}dod"
            if ! run_dod_audit; then
                all_passed=false
            fi
        fi

        # 6b. Security Source Scan
        local _sec_intensity
        _sec_intensity=$(echo "$audit_plan" | jq -r '.security // "targeted"' 2>/dev/null || echo "targeted")
        if [[ "$_sec_intensity" != "off" ]]; then
            echo ""
            info "Running security source scan (${_sec_intensity})..."
            audits_run_list="${audits_run_list:+${audits_run_list},}security"
            local sec_finding_count=0
            sec_finding_count=$(pipeline_security_source_scan 2>/dev/null) || true
            sec_finding_count="${sec_finding_count:-0}"
            if [[ "$sec_finding_count" -gt 0 ]]; then
                warn "Security source scan: ${sec_finding_count} finding(s)"
                total_critical=$((total_critical + sec_finding_count))
                all_passed=false
            else
                success "Security source scan: clean"
            fi
        fi

        # 7. Multi-dimensional quality checks
        echo ""
        info "Running multi-dimensional quality checks..."
        local quality_failures=0

        if ! quality_check_security; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_coverage; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_perf_regression; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_bundle_size; then
            quality_failures=$((quality_failures + 1))
        fi
        if ! quality_check_api_compat; then
            quality_failures=$((quality_failures + 1))
        fi

        if [[ "$quality_failures" -gt 0 ]]; then
            if [[ "$strict_quality" == "true" ]]; then
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (strict mode — blocking)"
                all_passed=false
            else
                warn "Multi-dimensional quality: ${quality_failures} check(s) failed (non-blocking)"
            fi
        else
            success "Multi-dimensional quality: all checks passed"
        fi

        # ── Convergence Detection ──
        # Count critical/high issues from all review artifacts
        local current_issue_count=0
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.md" ]]; then
            local adv_issues
            adv_issues=$(grep -ciE '\*\*\[?(Critical|Bug|critical|high)\]?\*\*' "$ARTIFACTS_DIR/adversarial-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${adv_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
            local adv_json_issues
            adv_json_issues=$(jq '[.[] | select(.severity == "critical" or .severity == "high")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
            current_issue_count=$((current_issue_count + ${adv_json_issues:-0}))
        fi
        if [[ -f "$ARTIFACTS_DIR/negative-review.md" ]]; then
            local neg_issues
            neg_issues=$(grep -ciE '\[Critical\]' "$ARTIFACTS_DIR/negative-review.md" 2>/dev/null || true)
            current_issue_count=$((current_issue_count + ${neg_issues:-0}))
        fi
        current_issue_count=$((current_issue_count + quality_failures))

        emit_event "compound.cycle" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cycle=$cycle" \
            "max_cycles=$max_cycles" \
            "passed=$all_passed" \
            "critical_issues=$current_issue_count" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Early exit: zero critical/high issues
        if [[ "$current_issue_count" -eq 0 ]] && $all_passed; then
            success "Compound quality passed on cycle ${cycle} — zero critical/high issues"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}

All quality checks clean:
- Adversarial review: ✅
- Negative prompting: ✅
- Developer simulation: ✅
- Architecture validation: ✅
- E2E validation: ✅
- DoD audit: ✅
- Security audit: ✅
- Coverage: ✅
- Performance: ✅
- Bundle size: ✅
- API compat: ✅" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod &>/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 100 0 0 0 "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        if $all_passed; then
            success "Compound quality passed on cycle ${cycle}"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"

            # DoD verification on successful pass
            local _dod_pass_rate=100
            if type pipeline_verify_dod &>/dev/null 2>&1; then
                pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
                if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
                    _dod_pass_rate=$(jq -r '.pass_rate // 100' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "100")
                fi
            fi

            pipeline_record_quality_score 95 0 "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true
            return 0
        fi

        # Check for plateau: issue count unchanged between cycles
        if [[ "$prev_issue_count" -ge 0 && "$current_issue_count" -eq "$prev_issue_count" && "$cycle" -gt 1 ]]; then
            warn "Convergence: quality plateau — ${current_issue_count} issues unchanged between cycles"
            emit_event "compound.plateau" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "issue_count=$current_issue_count"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "⚠️ **Compound quality plateau** — ${current_issue_count} issues unchanged after cycle ${cycle}. Stopping early." 2>/dev/null || true
            fi

            log_stage "compound_quality" "Plateau at cycle ${cycle}/${max_cycles} (${current_issue_count} issues)"
            return 1
        fi
        prev_issue_count="$current_issue_count"

        info "Convergence: ${current_issue_count} critical/high issues remaining"

        # Intelligence: re-evaluate adaptive cycle limit based on convergence (only after first cycle)
        if [[ "$prev_issue_count" -ge 0 ]]; then
            local updated_limit
            updated_limit=$(pipeline_adaptive_cycles "$max_cycles" "compound_quality" "$current_issue_count" "$prev_issue_count" 2>/dev/null) || true
            if [[ -n "$updated_limit" && "$updated_limit" =~ ^[0-9]+$ && "$updated_limit" -gt 0 && "$updated_limit" != "$max_cycles" ]]; then
                info "Adaptive cycles: ${max_cycles} → ${updated_limit} (convergence signal)"
                max_cycles="$updated_limit"
            fi
        fi

        # Not all passed — rebuild if we have cycles left
        if [[ "$cycle" -lt "$max_cycles" ]]; then
            warn "Quality checks failed — rebuilding with feedback (cycle $((cycle + 1))/${max_cycles})"

            if ! compound_rebuild_with_feedback; then
                error "Rebuild with feedback failed"
                log_stage "compound_quality" "Rebuild failed on cycle ${cycle}"
                return 1
            fi

            # Re-run review stage too (since code changed)
            info "Re-running review after rebuild..."
            stage_review 2>/dev/null || true
        fi
    done

    # ── Quality Score Computation ──
    # Starting score: 100, deductions based on findings
    local quality_score=100

    # Count findings from artifact files
    if [[ -f "$ARTIFACTS_DIR/security-source-scan.json" ]]; then
        local _sec_critical
        _sec_critical=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        local _sec_major
        _sec_major=$(jq '[.[] | select(.severity == "major")] | length' "$ARTIFACTS_DIR/security-source-scan.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_sec_critical:-0}))
        total_major=$((total_major + ${_sec_major:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/adversarial-review.json" ]]; then
        local _adv_crit
        _adv_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_major
        _adv_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        local _adv_minor
        _adv_minor=$(jq '[.[] | select(.severity == "low" or .severity == "minor")] | length' "$ARTIFACTS_DIR/adversarial-review.json" 2>/dev/null || echo "0")
        total_critical=$((total_critical + ${_adv_crit:-0}))
        total_major=$((total_major + ${_adv_major:-0}))
        total_minor=$((total_minor + ${_adv_minor:-0}))
    fi
    if [[ -f "$ARTIFACTS_DIR/compound-architecture-validation.json" ]]; then
        local _arch_crit
        _arch_crit=$(jq '[.[] | select(.severity == "critical")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        local _arch_major
        _arch_major=$(jq '[.[] | select(.severity == "high" or .severity == "major")] | length' "$ARTIFACTS_DIR/compound-architecture-validation.json" 2>/dev/null || echo "0")
        total_major=$((total_major + ${_arch_crit:-0} + ${_arch_major:-0}))
    fi

    # Apply deductions
    quality_score=$((quality_score - (total_critical * 20) - (total_major * 10) - (total_minor * 2)))
    [[ "$quality_score" -lt 0 ]] && quality_score=0

    # DoD verification
    local _dod_pass_rate=0
    if type pipeline_verify_dod &>/dev/null 2>&1; then
        pipeline_verify_dod "$ARTIFACTS_DIR" 2>/dev/null || true
        if [[ -f "$ARTIFACTS_DIR/dod-verification.json" ]]; then
            _dod_pass_rate=$(jq -r '.pass_rate // 0' "$ARTIFACTS_DIR/dod-verification.json" 2>/dev/null || echo "0")
        fi
    fi

    # Record quality score
    pipeline_record_quality_score "$quality_score" "$total_critical" "$total_major" "$total_minor" "$_dod_pass_rate" "$audits_run_list" 2>/dev/null || true

    # ── Quality Gate ──
    local compound_quality_blocking
    compound_quality_blocking=$(jq -r --arg id "compound_quality" \
        '(.stages[] | select(.id == $id) | .config.compound_quality_blocking) // true' \
        "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$compound_quality_blocking" || "$compound_quality_blocking" == "null" ]] && compound_quality_blocking="true"

    if [[ "$quality_score" -lt 60 && "$compound_quality_blocking" == "true" ]]; then
        emit_event "pipeline.quality_gate_failed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "quality_score=$quality_score" \
            "critical=$total_critical" \
            "major=$total_major"

        error "Quality gate FAILED: score ${quality_score}/100 (critical: ${total_critical}, major: ${total_major}, minor: ${total_minor})"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Quality gate failed** — score ${quality_score}/100

| Finding Type | Count | Deduction |
|---|---|---|
| Critical | ${total_critical} | -$((total_critical * 20)) |
| Major | ${total_major} | -$((total_major * 10)) |
| Minor | ${total_minor} | -$((total_minor * 2)) |

DoD pass rate: ${_dod_pass_rate}%
Quality issues remain after ${max_cycles} cycles. Check artifacts for details." 2>/dev/null || true
        fi

        log_stage "compound_quality" "Quality gate failed: ${quality_score}/100 after ${max_cycles} cycles"
        return 1
    fi

    # Exhausted all cycles but quality score is above threshold
    if [[ "$quality_score" -ge 60 ]]; then
        warn "Compound quality: score ${quality_score}/100 after ${max_cycles} cycles (above threshold, proceeding)"

        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "⚠️ **Compound quality** — score ${quality_score}/100 after ${max_cycles} cycles

Some issues remain but quality score is above threshold. Proceeding." 2>/dev/null || true
        fi

        log_stage "compound_quality" "Passed with score ${quality_score}/100 after ${max_cycles} cycles"
        return 0
    fi

    error "Compound quality exhausted after ${max_cycles} cycles"

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "❌ **Compound quality failed** after ${max_cycles} cycles

Quality issues remain. Check artifacts for details." 2>/dev/null || true
    fi

    log_stage "compound_quality" "Failed after ${max_cycles} cycles"
    return 1
}

# ─── Error Classification ──────────────────────────────────────────────────
# Classifies errors to determine whether retrying makes sense.
# Returns: "infrastructure", "logic", "configuration", or "unknown"

classify_error() {
    local stage_id="$1"
    local log_file="${ARTIFACTS_DIR}/${stage_id}-results.log"
    [[ ! -f "$log_file" ]] && log_file="${ARTIFACTS_DIR}/test-results.log"
    [[ ! -f "$log_file" ]] && { echo "unknown"; return; }

    local log_tail
    log_tail=$(tail -50 "$log_file" 2>/dev/null || echo "")

    # Generate error signature for history lookup
    local error_sig
    error_sig=$(echo "$log_tail" | grep -iE 'error|fail|exception|fatal' 2>/dev/null | head -3 | cksum | awk '{print $1}' || echo "0")

    # Check classification history first (learned from previous runs)
    local class_history="${HOME}/.shipwright/optimization/error-classifications.json"
    if [[ -f "$class_history" ]]; then
        local cached_class
        cached_class=$(jq -r --arg sig "$error_sig" '.[$sig].classification // empty' "$class_history" 2>/dev/null || true)
        if [[ -n "$cached_class" && "$cached_class" != "null" ]]; then
            echo "$cached_class"
            return
        fi
    fi

    local classification="unknown"

    # Infrastructure errors: timeout, OOM, network — retry makes sense
    if echo "$log_tail" | grep -qiE 'timeout|timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|network|socket hang up|OOM|out of memory|killed|signal 9|Cannot allocate memory'; then
        classification="infrastructure"
    # Configuration errors: missing env, wrong path — don't retry, escalate
    elif echo "$log_tail" | grep -qiE 'ENOENT|not found|No such file|command not found|MODULE_NOT_FOUND|Cannot find module|missing.*env|undefined variable|permission denied|EACCES'; then
        classification="configuration"
    # Logic errors: assertion failures, type errors — retry won't help without code change
    elif echo "$log_tail" | grep -qiE 'AssertionError|assert.*fail|Expected.*but.*got|TypeError|ReferenceError|SyntaxError|CompileError|type mismatch|cannot assign|incompatible type'; then
        classification="logic"
    # Build errors: compilation failures
    elif echo "$log_tail" | grep -qiE 'error\[E[0-9]+\]|error: aborting|FAILED.*compile|build failed|tsc.*error|eslint.*error'; then
        classification="logic"
    # Intelligence fallback: Claude classification for unknown errors
    elif [[ "$classification" == "unknown" ]] && type intelligence_search_memory &>/dev/null 2>&1 && command -v claude &>/dev/null; then
        local ai_class
        ai_class=$(claude --print --output-format text -p "Classify this error as exactly one of: infrastructure, configuration, logic, unknown.

Error output:
$(echo "$log_tail" | tail -20)

Reply with ONLY the classification word, nothing else." --model haiku < /dev/null 2>/dev/null || true)
        ai_class=$(echo "$ai_class" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        case "$ai_class" in
            infrastructure|configuration|logic) classification="$ai_class" ;;
        esac
    fi

    # Map retry categories to shared taxonomy (from lib/compat.sh SW_ERROR_CATEGORIES)
    # Retry uses: infrastructure, configuration, logic, unknown
    # Shared uses: test_failure, build_error, lint_error, timeout, dependency, flaky, config, security, permission, unknown
    local canonical_category="unknown"
    case "$classification" in
        infrastructure) canonical_category="timeout" ;;
        configuration)  canonical_category="config" ;;
        logic)
            case "$stage_id" in
                test) canonical_category="test_failure" ;;
                *)    canonical_category="build_error" ;;
            esac
            ;;
    esac

    # Record classification for future runs (using both retry and canonical categories)
    if [[ -n "$error_sig" && "$error_sig" != "0" ]]; then
        local class_dir="${HOME}/.shipwright/optimization"
        mkdir -p "$class_dir" 2>/dev/null || true
        local tmp_class
        tmp_class="$(mktemp)"
        if [[ -f "$class_history" ]]; then
            jq --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '.[$sig] = {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}' \
                "$class_history" > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        else
            jq -n --arg sig "$error_sig" --arg cls "$classification" --arg canon "$canonical_category" --arg stage "$stage_id" \
                '{($sig): {"classification": $cls, "canonical": $canon, "stage": $stage, "recorded_at": now}}' \
                > "$tmp_class" 2>/dev/null && \
                mv "$tmp_class" "$class_history" || rm -f "$tmp_class"
        fi
    fi

    echo "$classification"
}

# ─── Stage Runner ───────────────────────────────────────────────────────────

run_stage_with_retry() {
    local stage_id="$1"
    local max_retries
    max_retries=$(jq -r --arg id "$stage_id" '(.stages[] | select(.id == $id) | .config.retries) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_retries" || "$max_retries" == "null" ]] && max_retries=0

    local attempt=0
    local prev_error_class=""
    while true; do
        if "stage_${stage_id}"; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "$attempt" -gt "$max_retries" ]]; then
            return 1
        fi

        # Classify the error to decide whether retry makes sense
        local error_class
        error_class=$(classify_error "$stage_id")

        emit_event "retry.classified" \
            "issue=${ISSUE_NUMBER:-0}" \
            "stage=$stage_id" \
            "attempt=$attempt" \
            "error_class=$error_class"

        case "$error_class" in
            infrastructure)
                info "Error classified as infrastructure (timeout/network/OOM) — retry makes sense"
                ;;
            configuration)
                error "Error classified as configuration (missing env/path) — skipping retry, escalating"
                emit_event "retry.escalated" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$stage_id" \
                    "reason=configuration_error"
                return 1
                ;;
            logic)
                if [[ "$error_class" == "$prev_error_class" ]]; then
                    error "Error classified as logic (assertion/type error) with same class — retry won't help without code change"
                    emit_event "retry.skipped" \
                        "issue=${ISSUE_NUMBER:-0}" \
                        "stage=$stage_id" \
                        "reason=repeated_logic_error"
                    return 1
                fi
                warn "Error classified as logic — retrying once in case build fixes it"
                ;;
            *)
                info "Error classification: unknown — retrying"
                ;;
        esac
        prev_error_class="$error_class"

        warn "Stage $stage_id failed (attempt $attempt/$((max_retries + 1)), class: $error_class) — retrying..."
        # Exponential backoff with jitter to avoid thundering herd
        local backoff=$((2 ** attempt))
        [[ "$backoff" -gt 16 ]] && backoff=16
        local jitter=$(( RANDOM % (backoff + 1) ))
        local total_sleep=$((backoff + jitter))
        info "Backing off ${total_sleep}s before retry..."
        sleep "$total_sleep"
    done
}

# ─── Self-Healing Build→Test Feedback Loop ─────────────────────────────────
# When tests fail after a build, this captures the error and re-runs the build
# with the error context, so Claude can fix the issue automatically.

self_healing_build_test() {
    local cycle=0
    local max_cycles="$BUILD_TEST_RETRIES"
    local last_test_error=""

    # Convergence tracking
    local prev_error_sig="" consecutive_same_error=0
    local prev_fail_count=0 zero_convergence_streak=0

    # Vitals-driven adaptive limit (preferred over static BUILD_TEST_RETRIES)
    if type pipeline_adaptive_limit &>/dev/null 2>&1; then
        local _vitals_json=""
        if type pipeline_compute_vitals &>/dev/null 2>&1; then
            _vitals_json=$(pipeline_compute_vitals "$STATE_FILE" "$ARTIFACTS_DIR" "${ISSUE_NUMBER:-}" 2>/dev/null) || true
        fi
        local vitals_limit
        vitals_limit=$(pipeline_adaptive_limit "build_test" "$_vitals_json" 2>/dev/null) || true
        if [[ -n "$vitals_limit" && "$vitals_limit" =~ ^[0-9]+$ && "$vitals_limit" -gt 0 ]]; then
            info "Vitals-driven build-test limit: ${max_cycles} → ${vitals_limit}"
            max_cycles="$vitals_limit"
            emit_event "vitals.adaptive_limit" \
                "issue=${ISSUE_NUMBER:-0}" \
                "context=build_test" \
                "original=$BUILD_TEST_RETRIES" \
                "vitals_limit=$vitals_limit"
        fi
    # Fallback: intelligence-based adaptive limits
    elif type composer_estimate_iterations &>/dev/null 2>&1; then
        local estimated
        estimated=$(composer_estimate_iterations \
            "${INTELLIGENCE_ANALYSIS:-{}}" \
            "${HOME}/.shipwright/optimization/iteration-model.json" 2>/dev/null || echo "")
        if [[ -n "$estimated" && "$estimated" =~ ^[0-9]+$ && "$estimated" -gt 0 ]]; then
            max_cycles="$estimated"
            emit_event "intelligence.adaptive_iterations" \
                "issue=${ISSUE_NUMBER:-0}" \
                "estimated=$estimated" \
                "original=$BUILD_TEST_RETRIES"
        fi
    fi

    # Fallback: adaptive cycle limits from optimization data
    if [[ "$max_cycles" == "$BUILD_TEST_RETRIES" ]]; then
        local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
        if [[ -f "$_iter_model" ]]; then
            local adaptive_bt_limit
            adaptive_bt_limit=$(pipeline_adaptive_cycles "$max_cycles" "build_test" "0" "-1" 2>/dev/null) || true
            if [[ -n "$adaptive_bt_limit" && "$adaptive_bt_limit" =~ ^[0-9]+$ && "$adaptive_bt_limit" -gt 0 && "$adaptive_bt_limit" != "$max_cycles" ]]; then
                info "Adaptive build-test cycles: ${max_cycles} → ${adaptive_bt_limit}"
                max_cycles="$adaptive_bt_limit"
            fi
        fi
    fi

    while [[ "$cycle" -le "$max_cycles" ]]; do
        cycle=$((cycle + 1))

        if [[ "$cycle" -gt 1 ]]; then
            SELF_HEAL_COUNT=$((SELF_HEAL_COUNT + 1))
            echo ""
            echo -e "${YELLOW}${BOLD}━━━ Self-Healing Cycle ${cycle}/$((max_cycles + 1)) ━━━${RESET}"
            info "Feeding test failure back to build loop..."

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "🔄 **Self-healing cycle ${cycle}** — rebuilding with error context" 2>/dev/null || true
            fi

            # Reset build/test stage statuses for retry
            set_stage_status "build" "retrying"
            set_stage_status "test" "pending"
        fi

        # ── Run Build Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: build${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="build"

        # Inject error context on retry cycles
        if [[ "$cycle" -gt 1 && -n "$last_test_error" ]]; then
            # Query memory for known fixes
            local _memory_fix=""
            if type memory_closed_loop_inject &>/dev/null 2>&1; then
                local _error_sig_short
                _error_sig_short=$(echo "$last_test_error" | head -3 || echo "")
                _memory_fix=$(memory_closed_loop_inject "$_error_sig_short" 2>/dev/null) || true
            fi

            local memory_prefix=""
            if [[ -n "$_memory_fix" ]]; then
                info "Memory suggests fix: $(echo "$_memory_fix" | head -1)"
                memory_prefix="KNOWN FIX (from past success): ${_memory_fix}

"
            fi

            # Temporarily augment the goal with error context
            local original_goal="$GOAL"
            GOAL="$GOAL

${memory_prefix}IMPORTANT — Previous build attempt failed tests. Fix these errors:
$last_test_error

Focus on fixing the failing tests while keeping all passing tests working."

            update_status "running" "build"
            record_stage_start "build"

            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot &>/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                GOAL="$original_goal"
                return 1
            fi
            GOAL="$original_goal"
        else
            update_status "running" "build"
            record_stage_start "build"

            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
                if type pipeline_emit_progress_snapshot &>/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                    local _diff_count
                    _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                    local _snap_files _snap_error
                    _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                    _snap_files="${_snap_files:-0}"
                    _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                    _snap_error="${_snap_error:-}"
                    pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-build}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
                fi
            else
                mark_stage_failed "build"
                return 1
            fi
        fi

        # ── Run Test Stage ──
        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: test${RESET} ${DIM}[cycle ${cycle}]${RESET}"
        CURRENT_STAGE_ID="test"
        update_status "running" "test"
        record_stage_start "test"

        if run_stage_with_retry "test"; then
            mark_stage_complete "test"
            local timing
            timing=$(get_stage_timing "test")
            success "Stage ${BOLD}test${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "convergence.tests_passed" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle"
            if type pipeline_emit_progress_snapshot &>/dev/null 2>&1 && [[ -n "${ISSUE_NUMBER:-}" ]]; then
                local _diff_count
                _diff_count=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1) || true
                local _snap_files _snap_error
                _snap_files=$(git diff --stat HEAD~1 2>/dev/null | tail -1 | grep -oE '[0-9]+' | head -1 || true)
                _snap_files="${_snap_files:-0}"
                _snap_error=$(tail -1 "$ARTIFACTS_DIR/error-log.jsonl" 2>/dev/null | jq -r '.error // ""' 2>/dev/null || true)
                _snap_error="${_snap_error:-}"
                pipeline_emit_progress_snapshot "${ISSUE_NUMBER}" "${CURRENT_STAGE_ID:-test}" "${cycle:-0}" "${_diff_count:-0}" "${_snap_files}" "${_snap_error}" 2>/dev/null || true
            fi
            return 0  # Tests passed!
        fi

        # Tests failed — capture error for next cycle
        local test_log="$ARTIFACTS_DIR/test-results.log"
        last_test_error=$(tail -30 "$test_log" 2>/dev/null || echo "Test command failed with no output")
        mark_stage_failed "test"

        # ── Convergence Detection ──
        # Hash the error output to detect repeated failures
        local error_sig
        error_sig=$(echo "$last_test_error" | shasum -a 256 2>/dev/null | cut -c1-16 || echo "unknown")

        # Count failing tests (extract from common patterns)
        local current_fail_count=0
        current_fail_count=$(grep -ciE 'fail|error|FAIL' "$test_log" 2>/dev/null || true)
        current_fail_count="${current_fail_count:-0}"

        if [[ "$error_sig" == "$prev_error_sig" ]]; then
            consecutive_same_error=$((consecutive_same_error + 1))
        else
            consecutive_same_error=1
        fi
        prev_error_sig="$error_sig"

        # Check: same error 3 times consecutively → stuck
        if [[ "$consecutive_same_error" -ge 3 ]]; then
            error "Convergence: stuck on same error for 3 consecutive cycles — exiting early"
            emit_event "convergence.stuck" \
                "issue=${ISSUE_NUMBER:-0}" \
                "cycle=$cycle" \
                "error_sig=$error_sig" \
                "consecutive=$consecutive_same_error"
            notify "Build Convergence" "Stuck on unfixable error after ${cycle} cycles" "error"
            return 1
        fi

        # Track convergence rate: did we reduce failures?
        if [[ "$cycle" -gt 1 && "$prev_fail_count" -gt 0 ]]; then
            if [[ "$current_fail_count" -ge "$prev_fail_count" ]]; then
                zero_convergence_streak=$((zero_convergence_streak + 1))
            else
                zero_convergence_streak=0
            fi

            # Check: zero convergence for 2 consecutive iterations → plateau
            if [[ "$zero_convergence_streak" -ge 2 ]]; then
                error "Convergence: no progress for 2 consecutive cycles (${current_fail_count} failures remain) — exiting early"
                emit_event "convergence.plateau" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "cycle=$cycle" \
                    "fail_count=$current_fail_count" \
                    "streak=$zero_convergence_streak"
                notify "Build Convergence" "No progress after ${cycle} cycles — plateau reached" "error"
                return 1
            fi
        fi
        prev_fail_count="$current_fail_count"

        info "Convergence: error_sig=${error_sig:0:8} repeat=${consecutive_same_error} failures=${current_fail_count} no_progress=${zero_convergence_streak}"

        if [[ "$cycle" -le "$max_cycles" ]]; then
            warn "Tests failed — will attempt self-healing (cycle $((cycle + 1))/$((max_cycles + 1)))"
            notify "Self-Healing" "Tests failed on cycle ${cycle}, retrying..." "warn"
        fi
    done

    error "Self-healing exhausted after $((max_cycles + 1)) cycles"
    notify "Self-Healing Failed" "Tests still failing after $((max_cycles + 1)) build-test cycles" "error"
    return 1
}

# ─── Auto-Rebase ──────────────────────────────────────────────────────────

auto_rebase() {
    info "Syncing with ${BASE_BRANCH}..."

    # Fetch latest
    git fetch origin "$BASE_BRANCH" --quiet 2>/dev/null || {
        warn "Could not fetch origin/${BASE_BRANCH}"
        return 0
    }

    # Check if rebase is needed
    local behind
    behind=$(git rev-list --count "HEAD..origin/${BASE_BRANCH}" 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        success "Already up to date with ${BASE_BRANCH}"
        return 0
    fi

    info "Rebasing onto origin/${BASE_BRANCH} ($behind commits behind)..."
    if git rebase "origin/${BASE_BRANCH}" --quiet 2>/dev/null; then
        success "Rebase successful"
    else
        warn "Rebase conflict detected — aborting rebase"
        git rebase --abort 2>/dev/null || true
        warn "Falling back to merge..."
        if git merge "origin/${BASE_BRANCH}" --no-edit --quiet 2>/dev/null; then
            success "Merge successful"
        else
            git merge --abort 2>/dev/null || true
            error "Both rebase and merge failed — manual intervention needed"
            return 1
        fi
    fi
}

run_pipeline() {
    local stages
    stages=$(jq -c '.stages[]' "$PIPELINE_CONFIG")

    local stage_count enabled_count
    stage_count=$(jq '.stages | length' "$PIPELINE_CONFIG")
    enabled_count=$(jq '[.stages[] | select(.enabled == true)] | length' "$PIPELINE_CONFIG")
    local completed=0

    # Check which stages are enabled to determine if we use the self-healing loop
    local build_enabled test_enabled
    build_enabled=$(jq -r '.stages[] | select(.id == "build") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    test_enabled=$(jq -r '.stages[] | select(.id == "test") | .enabled' "$PIPELINE_CONFIG" 2>/dev/null)
    local use_self_healing=false
    if [[ "$build_enabled" == "true" && "$test_enabled" == "true" && "$BUILD_TEST_RETRIES" -gt 0 ]]; then
        use_self_healing=true
    fi

    while IFS= read -r -u 3 stage; do
        local id enabled gate
        id=$(echo "$stage" | jq -r '.id')
        enabled=$(echo "$stage" | jq -r '.enabled')
        gate=$(echo "$stage" | jq -r '.gate')

        CURRENT_STAGE_ID="$id"

        # Human intervention: check for skip-stage directive
        if [[ -f "$ARTIFACTS_DIR/skip-stage.txt" ]]; then
            local skip_list
            skip_list="$(cat "$ARTIFACTS_DIR/skip-stage.txt" 2>/dev/null || true)"
            if echo "$skip_list" | grep -qx "$id" 2>/dev/null; then
                info "Stage ${BOLD}${id}${RESET} skipped by human directive"
                emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=human_skip"
                # Remove this stage from the skip file
                local tmp_skip
                tmp_skip="$(mktemp)"
                grep -vx "$id" "$ARTIFACTS_DIR/skip-stage.txt" > "$tmp_skip" 2>/dev/null || true
                mv "$tmp_skip" "$ARTIFACTS_DIR/skip-stage.txt"
                continue
            fi
        fi

        # Human intervention: check for human message
        if [[ -f "$ARTIFACTS_DIR/human-message.txt" ]]; then
            local human_msg
            human_msg="$(cat "$ARTIFACTS_DIR/human-message.txt" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo ""
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                emit_event "pipeline.human_message" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "message=$human_msg"
                rm -f "$ARTIFACTS_DIR/human-message.txt"
            fi
        fi

        if [[ "$enabled" != "true" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (disabled)${RESET}"
            continue
        fi

        # Intelligence: evaluate whether to skip this stage
        local skip_reason=""
        skip_reason=$(pipeline_should_skip_stage "$id" 2>/dev/null) || true
        if [[ -n "$skip_reason" ]]; then
            echo -e "  ${DIM}○ ${id} — skipped (intelligence: ${skip_reason})${RESET}"
            set_stage_status "$id" "complete"
            completed=$((completed + 1))
            continue
        fi

        local stage_status
        stage_status=$(get_stage_status "$id")
        if [[ "$stage_status" == "complete" ]]; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— already complete${RESET}"
            completed=$((completed + 1))
            continue
        fi

        # CI resume: skip stages marked as completed from previous run
        if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "$id"; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— skipped (CI resume)${RESET}"
            set_stage_status "$id" "complete"
            completed=$((completed + 1))
            emit_event "stage.skipped" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "reason=ci_resume"
            continue
        fi

        # Self-healing build→test loop: when we hit build, run both together
        if [[ "$id" == "build" && "$use_self_healing" == "true" ]]; then
            # Gate check for build
            local build_gate
            build_gate=$(echo "$stage" | jq -r '.gate')
            if [[ "$build_gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
                show_stage_preview "build"
                local answer=""
                read -rp "  Proceed with build+test (self-healing)? [Y/n] " answer
                if [[ "$answer" =~ ^[Nn] ]]; then
                    update_status "paused" "build"
                    info "Pipeline paused. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                    return 0
                fi
            fi

            if self_healing_build_test; then
                completed=$((completed + 2))  # Both build and test

                # Intelligence: reassess complexity after build+test
                local reassessment
                reassessment=$(pipeline_reassess_complexity 2>/dev/null) || true
                if [[ -n "$reassessment" && "$reassessment" != "as_expected" ]]; then
                    info "Complexity reassessment: ${reassessment}"
                fi
            else
                update_status "failed" "test"
                error "Pipeline failed: build→test self-healing exhausted"
                return 1
            fi
            continue
        fi

        # Skip test if already handled by self-healing loop
        if [[ "$id" == "test" && "$use_self_healing" == "true" ]]; then
            stage_status=$(get_stage_status "test")
            if [[ "$stage_status" == "complete" ]]; then
                echo -e "  ${GREEN}✓ test${RESET} ${DIM}— completed in build→test loop${RESET}"
            fi
            continue
        fi

        # Gate check
        if [[ "$gate" == "approve" && "$SKIP_GATES" != "true" ]]; then
            show_stage_preview "$id"
            local answer=""
            read -rp "  Proceed with ${id}? [Y/n] " answer
            if [[ "$answer" =~ ^[Nn] ]]; then
                update_status "paused" "$id"
                info "Pipeline paused at ${BOLD}$id${RESET}. Resume with: ${DIM}shipwright pipeline resume${RESET}"
                return 0
            fi
        fi

        # Budget enforcement check (skip with --ignore-budget)
        if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
            local budget_rc=0
            bash "$SCRIPT_DIR/sw-cost.sh" check-budget 2>/dev/null || budget_rc=$?
            if [[ "$budget_rc" -eq 2 ]]; then
                warn "Daily budget exceeded — pausing pipeline before stage ${BOLD}$id${RESET}"
                warn "Resume with --ignore-budget to override, or wait until tomorrow"
                emit_event "pipeline.budget_paused" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
                update_status "paused" "$id"
                return 0
            fi
        fi

        # Intelligence: per-stage model routing with A/B testing
        if type intelligence_recommend_model &>/dev/null 2>&1; then
            local stage_complexity="${INTELLIGENCE_COMPLEXITY:-5}"
            local budget_remaining=""
            if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
                budget_remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
            fi
            local recommended_model
            recommended_model=$(intelligence_recommend_model "$id" "$stage_complexity" "$budget_remaining" 2>/dev/null || echo "")
            if [[ -n "$recommended_model" && "$recommended_model" != "null" ]]; then
                # A/B testing: decide whether to use the recommended model
                local ab_ratio=20  # default 20% use recommended model
                local daemon_cfg="${PROJECT_ROOT}/.claude/daemon-config.json"
                if [[ -f "$daemon_cfg" ]]; then
                    local cfg_ratio
                    cfg_ratio=$(jq -r '.intelligence.ab_test_ratio // 0.2' "$daemon_cfg" 2>/dev/null || echo "0.2")
                    # Convert ratio (0.0-1.0) to percentage (0-100)
                    ab_ratio=$(awk -v r="$cfg_ratio" 'BEGIN{printf "%d", r * 100}' 2>/dev/null || echo "20")
                fi

                # Check if we have enough data points to graduate from A/B testing
                local routing_file="${HOME}/.shipwright/optimization/model-routing.json"
                local use_recommended=false
                local ab_group="control"

                if [[ -f "$routing_file" ]]; then
                    local stage_samples
                    stage_samples=$(jq -r --arg s "$id" '.[$s].sonnet_samples // 0' "$routing_file" 2>/dev/null || echo "0")
                    local total_samples
                    total_samples=$(jq -r --arg s "$id" '((.[$s].sonnet_samples // 0) + (.[$s].opus_samples // 0))' "$routing_file" 2>/dev/null || echo "0")

                    if [[ "$total_samples" -ge 50 ]]; then
                        # Enough data — use optimizer's recommendation as default
                        use_recommended=true
                        ab_group="graduated"
                    fi
                fi

                if [[ "$use_recommended" != "true" ]]; then
                    # A/B test: RANDOM % 100 < ab_ratio → use recommended
                    local roll=$((RANDOM % 100))
                    if [[ "$roll" -lt "$ab_ratio" ]]; then
                        use_recommended=true
                        ab_group="experiment"
                    else
                        ab_group="control"
                    fi
                fi

                if [[ "$use_recommended" == "true" ]]; then
                    export CLAUDE_MODEL="$recommended_model"
                else
                    export CLAUDE_MODEL="opus"
                fi

                emit_event "intelligence.model_ab" \
                    "issue=${ISSUE_NUMBER:-0}" \
                    "stage=$id" \
                    "recommended=$recommended_model" \
                    "applied=$CLAUDE_MODEL" \
                    "ab_group=$ab_group" \
                    "ab_ratio=$ab_ratio"
            fi
        fi

        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: ${id}${RESET} ${DIM}[$((completed + 1))/${enabled_count}]${RESET}"
        update_status "running" "$id"
        record_stage_start "$id"
        local stage_start_epoch
        stage_start_epoch=$(now_epoch)
        emit_event "stage.started" "issue=${ISSUE_NUMBER:-0}" "stage=$id"

        # Mark GitHub Check Run as in-progress
        if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_stage_update &>/dev/null 2>&1; then
            gh_checks_stage_update "$id" "in_progress" "" "Stage $id started" 2>/dev/null || true
        fi

        local stage_model_used="${CLAUDE_MODEL:-${MODEL:-opus}}"
        if run_stage_with_retry "$id"; then
            mark_stage_complete "$id"
            completed=$((completed + 1))
            local timing stage_dur_s
            timing=$(get_stage_timing "$id")
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            success "Stage ${BOLD}$id${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "stage.completed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s"
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|true" >> "${ARTIFACTS_DIR}/model-routing.log"
        else
            mark_stage_failed "$id"
            local stage_dur_s
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            error "Pipeline failed at stage: ${BOLD}$id${RESET}"
            update_status "failed" "$id"
            emit_event "stage.failed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s"
            # Log model used for prediction feedback
            echo "${id}|${stage_model_used}|false" >> "${ARTIFACTS_DIR}/model-routing.log"
            # Cancel any remaining in_progress check runs
            pipeline_cancel_check_runs 2>/dev/null || true
            return 1
        fi
    done 3<<< "$stages"

    # Pipeline complete!
    update_status "complete" ""
    local total_dur=""
    if [[ -n "$PIPELINE_START_EPOCH" ]]; then
        total_dur=$(format_duration $(( $(now_epoch) - PIPELINE_START_EPOCH )))
    fi

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"
    success "Pipeline complete! ${completed}/${enabled_count} stages passed in ${total_dur:-unknown}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════════${RESET}"

    # Show summary
    echo ""
    if [[ -f "$ARTIFACTS_DIR/pr-url.txt" ]]; then
        echo -e "  ${BOLD}PR:${RESET}        $(cat "$ARTIFACTS_DIR/pr-url.txt")"
    fi
    echo -e "  ${BOLD}Branch:${RESET}    $GIT_BRANCH"
    [[ -n "${GITHUB_ISSUE:-}" ]] && echo -e "  ${BOLD}Issue:${RESET}     $GITHUB_ISSUE"
    echo -e "  ${BOLD}Duration:${RESET}  $total_dur"
    echo -e "  ${BOLD}Artifacts:${RESET} $ARTIFACTS_DIR/"
    echo ""

    # Capture learnings to memory (success or failure)
    if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
        bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Final GitHub progress update
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
    fi

    # Post-completion cleanup
    pipeline_post_completion_cleanup
}

# ─── Post-Completion Cleanup ──────────────────────────────────────────────
# Cleans up transient artifacts after a successful pipeline run.

pipeline_post_completion_cleanup() {
    local cleaned=0

    # 1. Clear checkpoints (they only matter for resume; pipeline is done)
    if [[ -d "${ARTIFACTS_DIR}/checkpoints" ]]; then
        local cp_count=0
        local cp_file
        for cp_file in "${ARTIFACTS_DIR}/checkpoints"/*-checkpoint.json; do
            [[ -f "$cp_file" ]] || continue
            rm -f "$cp_file"
            cp_count=$((cp_count + 1))
        done
        if [[ "$cp_count" -gt 0 ]]; then
            cleaned=$((cleaned + cp_count))
        fi
    fi

    # 2. Clear per-run intelligence artifacts (not needed after completion)
    local intel_files=(
        "${ARTIFACTS_DIR}/classified-findings.json"
        "${ARTIFACTS_DIR}/reassessment.json"
        "${ARTIFACTS_DIR}/skip-stage.txt"
        "${ARTIFACTS_DIR}/human-message.txt"
    )
    local f
    for f in "${intel_files[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f"
            cleaned=$((cleaned + 1))
        fi
    done

    # 3. Clear stale pipeline state (mark as idle so next run starts clean)
    if [[ -f "$STATE_FILE" ]]; then
        # Reset status to idle (preserves the file for reference but unblocks new runs)
        local tmp_state
        tmp_state=$(mktemp)
        sed 's/^status: .*/status: idle/' "$STATE_FILE" > "$tmp_state" 2>/dev/null || true
        mv "$tmp_state" "$STATE_FILE"
    fi

    if [[ "$cleaned" -gt 0 ]]; then
        emit_event "pipeline.cleanup" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cleaned=$cleaned" \
            "type=post_completion"
    fi
}

# Cancel any lingering in_progress GitHub Check Runs (called on abort/interrupt)
pipeline_cancel_check_runs() {
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return
    fi

    if ! type gh_checks_stage_update &>/dev/null 2>&1; then
        return
    fi

    local ids_file="${ARTIFACTS_DIR:-/dev/null}/check-run-ids.json"
    [[ -f "$ids_file" ]] || return

    local stage
    while IFS= read -r stage; do
        [[ -z "$stage" ]] && continue
        gh_checks_stage_update "$stage" "completed" "cancelled" "Pipeline interrupted" 2>/dev/null || true
    done < <(jq -r 'keys[]' "$ids_file" 2>/dev/null || true)
}

# ─── Worktree Isolation ───────────────────────────────────────────────────
# Creates a git worktree for parallel-safe pipeline execution

pipeline_setup_worktree() {
    local worktree_base=".worktrees"
    local name="${WORKTREE_NAME}"

    # Auto-generate name from issue number or timestamp
    if [[ -z "$name" ]]; then
        if [[ -n "${ISSUE_NUMBER:-}" ]]; then
            name="pipeline-issue-${ISSUE_NUMBER}"
        else
            name="pipeline-$(date +%s)"
        fi
    fi

    local worktree_path="${worktree_base}/${name}"
    local branch_name="pipeline/${name}"

    info "Setting up worktree: ${DIM}${worktree_path}${RESET}"

    # Ensure worktree base exists
    mkdir -p "$worktree_base"

    # Remove stale worktree if it exists
    if [[ -d "$worktree_path" ]]; then
        warn "Worktree already exists — removing: ${worktree_path}"
        git worktree remove --force "$worktree_path" 2>/dev/null || rm -rf "$worktree_path"
    fi

    # Delete stale branch if it exists
    git branch -D "$branch_name" 2>/dev/null || true

    # Create worktree with new branch from current HEAD
    git worktree add -b "$branch_name" "$worktree_path" HEAD

    # Store original dir for cleanup, then cd into worktree
    ORIGINAL_REPO_DIR="$(pwd)"
    cd "$worktree_path"
    CLEANUP_WORKTREE=true

    success "Worktree ready: ${CYAN}${worktree_path}${RESET} (branch: ${branch_name})"
}

pipeline_cleanup_worktree() {
    if [[ "${CLEANUP_WORKTREE:-false}" != "true" ]]; then
        return
    fi

    local worktree_path
    worktree_path="$(pwd)"

    if [[ -n "${ORIGINAL_REPO_DIR:-}" && "$worktree_path" != "$ORIGINAL_REPO_DIR" ]]; then
        cd "$ORIGINAL_REPO_DIR" 2>/dev/null || cd /
        info "Cleaning up worktree: ${DIM}${worktree_path}${RESET}"
        git worktree remove --force "$worktree_path" 2>/dev/null || true
    fi
}

# ─── Subcommands ────────────────────────────────────────────────────────────

pipeline_start() {
    if [[ -z "$GOAL" && -z "$ISSUE_NUMBER" ]]; then
        error "Must provide --goal or --issue"
        echo -e "  Example: ${DIM}shipwright pipeline start --goal \"Add JWT auth\"${RESET}"
        echo -e "  Example: ${DIM}shipwright pipeline start --issue 123${RESET}"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        error "jq is required. Install it: brew install jq"
        exit 1
    fi

    # Set up worktree isolation if requested
    if [[ "$AUTO_WORKTREE" == "true" ]]; then
        pipeline_setup_worktree
    fi

    # Register worktree cleanup on exit (chain with existing cleanup)
    if [[ "$CLEANUP_WORKTREE" == "true" ]]; then
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' SIGINT SIGTERM
        trap 'pipeline_cleanup_worktree; cleanup_on_exit' EXIT
    fi

    setup_dirs

    # Check for existing pipeline
    if [[ -f "$STATE_FILE" ]]; then
        local existing_status
        existing_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)
        if [[ "$existing_status" == "running" || "$existing_status" == "paused" || "$existing_status" == "interrupted" ]]; then
            warn "A pipeline is already in progress (status: $existing_status)"
            echo -e "  Resume it: ${DIM}shipwright pipeline resume${RESET}"
            echo -e "  Abort it:  ${DIM}shipwright pipeline abort${RESET}"
            exit 1
        fi
    fi

    # Pre-flight checks
    preflight_checks || exit 1

    # Initialize GitHub integration
    gh_init

    load_pipeline_config
    initialize_state

    # CI resume: restore branch + goal context when intake is skipped
    if [[ -n "${COMPLETED_STAGES:-}" ]] && echo "$COMPLETED_STAGES" | tr ',' '\n' | grep -qx "intake"; then
        # Intake was completed in a previous run — restore context
        # The workflow merges the partial work branch, so code changes are on HEAD

        # Restore GOAL from issue if not already set
        if [[ -z "$GOAL" && -n "$ISSUE_NUMBER" ]]; then
            GOAL=$(gh issue view "$ISSUE_NUMBER" --json title -q .title 2>/dev/null || echo "Issue #${ISSUE_NUMBER}")
            info "CI resume: goal from issue — ${GOAL}"
        fi

        # Restore branch context
        if [[ -z "$GIT_BRANCH" ]]; then
            local ci_branch="ci/issue-${ISSUE_NUMBER}"
            info "CI resume: creating branch ${ci_branch} from current HEAD"
            git checkout -b "$ci_branch" 2>/dev/null || git checkout "$ci_branch" 2>/dev/null || true
            GIT_BRANCH="$ci_branch"
        elif [[ "$(git branch --show-current 2>/dev/null)" != "$GIT_BRANCH" ]]; then
            info "CI resume: checking out branch ${GIT_BRANCH}"
            git checkout -b "$GIT_BRANCH" 2>/dev/null || git checkout "$GIT_BRANCH" 2>/dev/null || true
        fi
        write_state 2>/dev/null || true
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright pipeline — Autonomous Feature Delivery               ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Comprehensive environment summary
    if [[ -n "$GOAL" ]]; then
        echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    fi
    if [[ -n "$ISSUE_NUMBER" ]]; then
        echo -e "  ${BOLD}Issue:${RESET}       #$ISSUE_NUMBER"
    fi

    echo -e "  ${BOLD}Pipeline:${RESET}    $PIPELINE_NAME"

    local enabled_stages
    enabled_stages=$(jq -r '.stages[] | select(.enabled == true) | .id' "$PIPELINE_CONFIG" | tr '\n' ' ')
    echo -e "  ${BOLD}Stages:${RESET}      $enabled_stages"

    local gate_count
    gate_count=$(jq '[.stages[] | select(.gate == "approve" and .enabled == true)] | length' "$PIPELINE_CONFIG")
    if [[ "$SKIP_GATES" == "true" ]]; then
        echo -e "  ${BOLD}Gates:${RESET}       ${YELLOW}all auto (--skip-gates)${RESET}"
    else
        echo -e "  ${BOLD}Gates:${RESET}       ${gate_count} approval gate(s)"
    fi

    echo -e "  ${BOLD}Model:${RESET}       ${MODEL:-$(jq -r '.defaults.model // "opus"' "$PIPELINE_CONFIG")}"
    echo -e "  ${BOLD}Self-heal:${RESET}   ${BUILD_TEST_RETRIES} retry cycle(s)"

    if [[ "$GH_AVAILABLE" == "true" ]]; then
        echo -e "  ${BOLD}GitHub:${RESET}      ${GREEN}✓${RESET} ${DIM}${REPO_OWNER}/${REPO_NAME}${RESET}"
    else
        echo -e "  ${BOLD}GitHub:${RESET}      ${DIM}disabled${RESET}"
    fi

    if [[ -n "$SLACK_WEBHOOK" ]]; then
        echo -e "  ${BOLD}Slack:${RESET}       ${GREEN}✓${RESET} notifications enabled"
    fi

    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        info "Dry run — no stages will execute"
        return 0
    fi

    # Start background heartbeat writer
    start_heartbeat

    # Initialize GitHub Check Runs for all pipeline stages
    if [[ "${NO_GITHUB:-false}" != "true" ]] && type gh_checks_pipeline_start &>/dev/null 2>&1; then
        local head_sha
        head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
        if [[ -n "$head_sha" && -n "$REPO_OWNER" && -n "$REPO_NAME" ]]; then
            local stages_json
            stages_json=$(jq -c '[.stages[] | select(.enabled == true) | .id]' "$PIPELINE_CONFIG" 2>/dev/null || echo '[]')
            gh_checks_pipeline_start "$REPO_OWNER" "$REPO_NAME" "$head_sha" "$stages_json" >/dev/null 2>/dev/null || true
            info "GitHub Checks: created check runs for pipeline stages"
        fi
    fi

    # Send start notification
    notify "Pipeline Started" "Goal: ${GOAL}\nPipeline: ${PIPELINE_NAME}" "info"

    emit_event "pipeline.started" \
        "issue=${ISSUE_NUMBER:-0}" \
        "pipeline=${PIPELINE_NAME}" \
        "model=${MODEL:-opus}" \
        "goal=${GOAL}"

    run_pipeline
    local exit_code=$?

    # Send completion notification + event
    local total_dur_s=""
    [[ -n "$PIPELINE_START_EPOCH" ]] && total_dur_s=$(( $(now_epoch) - PIPELINE_START_EPOCH ))
    if [[ "$exit_code" -eq 0 ]]; then
        local total_dur=""
        [[ -n "$total_dur_s" ]] && total_dur=$(format_duration "$total_dur_s")
        local pr_url
        pr_url=$(cat "$ARTIFACTS_DIR/pr-url.txt" 2>/dev/null || echo "")
        notify "Pipeline Complete" "Goal: ${GOAL}\nDuration: ${total_dur:-unknown}\nPR: ${pr_url:-N/A}" "success"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=success" \
            "duration_s=${total_dur_s:-0}" \
            "pr_url=${pr_url:-}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "self_heal_count=$SELF_HEAL_COUNT"
    else
        notify "Pipeline Failed" "Goal: ${GOAL}\nFailed at: ${CURRENT_STAGE_ID:-unknown}" "error"
        emit_event "pipeline.completed" \
            "issue=${ISSUE_NUMBER:-0}" \
            "result=failure" \
            "duration_s=${total_dur_s:-0}" \
            "failed_stage=${CURRENT_STAGE_ID:-unknown}" \
            "input_tokens=$TOTAL_INPUT_TOKENS" \
            "output_tokens=$TOTAL_OUTPUT_TOKENS" \
            "self_heal_count=$SELF_HEAL_COUNT"

        # Capture failure learnings to memory
        if [[ -x "$SCRIPT_DIR/sw-memory.sh" ]]; then
            bash "$SCRIPT_DIR/sw-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
            bash "$SCRIPT_DIR/sw-memory.sh" analyze-failure "$ARTIFACTS_DIR/.claude-tokens-${CURRENT_STAGE_ID:-build}.log" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true
        fi
    fi

    # ── Prediction Validation Events ──
    # Compare predicted vs actual outcomes for feedback loop calibration
    local pipeline_success="false"
    [[ "$exit_code" -eq 0 ]] && pipeline_success="true"

    # Complexity prediction vs actual iterations
    emit_event "prediction.validated" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_complexity=${INTELLIGENCE_COMPLEXITY:-0}" \
        "actual_iterations=$SELF_HEAL_COUNT" \
        "success=$pipeline_success"

    # Template outcome tracking
    emit_event "template.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "template=${PIPELINE_NAME}" \
        "success=$pipeline_success" \
        "duration_s=${total_dur_s:-0}"

    # Risk prediction vs actual failure
    local predicted_risk="${INTELLIGENCE_RISK_SCORE:-0}"
    emit_event "risk.outcome" \
        "issue=${ISSUE_NUMBER:-0}" \
        "predicted_risk=$predicted_risk" \
        "actual_failure=$([[ "$exit_code" -ne 0 ]] && echo "true" || echo "false")"

    # Per-stage model outcome events (read from stage timings)
    local routing_log="${ARTIFACTS_DIR}/model-routing.log"
    if [[ -f "$routing_log" ]]; then
        while IFS='|' read -r s_stage s_model s_success; do
            [[ -z "$s_stage" ]] && continue
            emit_event "model.outcome" \
                "issue=${ISSUE_NUMBER:-0}" \
                "stage=$s_stage" \
                "model=$s_model" \
                "success=$s_success"
        done < "$routing_log"
    fi

    # Record pipeline outcome for model routing feedback loop
    if type optimize_analyze_outcome &>/dev/null 2>&1; then
        optimize_analyze_outcome "$STATE_FILE" 2>/dev/null || true
    fi

    if type memory_finalize_pipeline &>/dev/null 2>&1; then
        memory_finalize_pipeline "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Emit cost event
    local model_key="${MODEL:-sonnet}"
    local input_cost output_cost total_cost
    input_cost=$(awk -v tokens="$TOTAL_INPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.input // 3")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    output_cost=$(awk -v tokens="$TOTAL_OUTPUT_TOKENS" -v rate="$(echo "$COST_MODEL_RATES" | jq -r ".${model_key}.output // 15")" 'BEGIN{printf "%.4f", (tokens / 1000000) * rate}')
    total_cost=$(awk -v i="$input_cost" -v o="$output_cost" 'BEGIN{printf "%.4f", i + o}')

    emit_event "pipeline.cost" \
        "input_tokens=$TOTAL_INPUT_TOKENS" \
        "output_tokens=$TOTAL_OUTPUT_TOKENS" \
        "model=$model_key" \
        "estimated_cost_usd=$total_cost"

    return $exit_code
}

pipeline_resume() {
    setup_dirs
    resume_state
    echo ""
    run_pipeline
}

pipeline_status() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline."
        echo -e "  Start one: ${DIM}shipwright pipeline start --goal \"...\"${RESET}"
        return
    fi

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline Status ━━━${RESET}"
    echo ""

    local p_name="" p_goal="" p_status="" p_branch="" p_stage="" p_started="" p_issue="" p_elapsed="" p_pr=""
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then break; else in_frontmatter=true; continue; fi
        fi
        if $in_frontmatter; then
            case "$line" in
                pipeline:*)      p_name="$(echo "${line#pipeline:}" | xargs)" ;;
                goal:*)          p_goal="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                status:*)        p_status="$(echo "${line#status:}" | xargs)" ;;
                branch:*)        p_branch="$(echo "${line#branch:}" | sed 's/^ *"//;s/" *$//')" ;;
                current_stage:*) p_stage="$(echo "${line#current_stage:}" | xargs)" ;;
                started_at:*)    p_started="$(echo "${line#started_at:}" | xargs)" ;;
                issue:*)         p_issue="$(echo "${line#issue:}" | sed 's/^ *"//;s/" *$//')" ;;
                elapsed:*)       p_elapsed="$(echo "${line#elapsed:}" | xargs)" ;;
                pr_number:*)     p_pr="$(echo "${line#pr_number:}" | xargs)" ;;
            esac
        fi
    done < "$STATE_FILE"

    local status_icon
    case "$p_status" in
        running)     status_icon="${CYAN}●${RESET}" ;;
        complete)    status_icon="${GREEN}✓${RESET}" ;;
        paused)      status_icon="${YELLOW}⏸${RESET}" ;;
        interrupted) status_icon="${YELLOW}⚡${RESET}" ;;
        failed)      status_icon="${RED}✗${RESET}" ;;
        aborted)     status_icon="${RED}◼${RESET}" ;;
        *)           status_icon="${DIM}○${RESET}" ;;
    esac

    echo -e "  ${BOLD}Pipeline:${RESET}  $p_name"
    echo -e "  ${BOLD}Goal:${RESET}      $p_goal"
    echo -e "  ${BOLD}Status:${RESET}    $status_icon $p_status"
    [[ -n "$p_branch" ]]  && echo -e "  ${BOLD}Branch:${RESET}    $p_branch"
    [[ -n "$p_issue" ]]   && echo -e "  ${BOLD}Issue:${RESET}     $p_issue"
    [[ -n "$p_pr" ]]      && echo -e "  ${BOLD}PR:${RESET}        #$p_pr"
    [[ -n "$p_stage" ]]   && echo -e "  ${BOLD}Stage:${RESET}     $p_stage"
    [[ -n "$p_started" ]] && echo -e "  ${BOLD}Started:${RESET}   $p_started"
    [[ -n "$p_elapsed" ]] && echo -e "  ${BOLD}Elapsed:${RESET}   $p_elapsed"

    echo ""
    echo -e "  ${BOLD}Stages:${RESET}"

    local in_stages=false
    while IFS= read -r line; do
        if [[ "$line" == "stages:" ]]; then
            in_stages=true; continue
        fi
        if $in_stages; then
            if [[ "$line" == "---" || ! "$line" =~ ^" " ]]; then break; fi
            local trimmed
            trimmed="$(echo "$line" | xargs)"
            if [[ "$trimmed" == *":"* ]]; then
                local sid="${trimmed%%:*}"
                local sst="${trimmed#*: }"
                local s_icon
                case "$sst" in
                    complete) s_icon="${GREEN}✓${RESET}" ;;
                    running)  s_icon="${CYAN}●${RESET}" ;;
                    failed)   s_icon="${RED}✗${RESET}" ;;
                    *)        s_icon="${DIM}○${RESET}" ;;
                esac
                echo -e "    $s_icon $sid"
            fi
        fi
    done < "$STATE_FILE"

    if [[ -d "$ARTIFACTS_DIR" ]]; then
        local artifact_count
        artifact_count=$(find "$ARTIFACTS_DIR" -type f 2>/dev/null | wc -l | xargs)
        if [[ "$artifact_count" -gt 0 ]]; then
            echo ""
            echo -e "  ${BOLD}Artifacts:${RESET} ($artifact_count files)"
            ls "$ARTIFACTS_DIR" 2>/dev/null | sed 's/^/    /'
        fi
    fi
    echo ""
}

pipeline_abort() {
    setup_dirs

    if [[ ! -f "$STATE_FILE" ]]; then
        info "No active pipeline to abort."
        return
    fi

    local current_status
    current_status=$(sed -n 's/^status: *//p' "$STATE_FILE" | head -1)

    if [[ "$current_status" == "complete" || "$current_status" == "aborted" ]]; then
        info "Pipeline already $current_status."
        return
    fi

    resume_state 2>/dev/null || true
    PIPELINE_STATUS="aborted"
    write_state

    # Update GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_init
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_comment_issue "$ISSUE_NUMBER" "⏹️ **Pipeline aborted** at stage: ${CURRENT_STAGE:-unknown}"
    fi

    warn "Pipeline aborted."
    echo -e "  State saved at: ${DIM}$STATE_FILE${RESET}"
}

pipeline_list() {
    local locations=(
        "$REPO_DIR/templates/pipelines"
        "$HOME/.shipwright/pipelines"
    )

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline Templates ━━━${RESET}"
    echo ""

    local found=false
    for dir in "${locations[@]}"; do
        if [[ -d "$dir" ]]; then
            for f in "$dir"/*.json; do
                [[ -f "$f" ]] || continue
                found=true
                local name desc stages_enabled gate_count
                name=$(jq -r '.name' "$f" 2>/dev/null)
                desc=$(jq -r '.description' "$f" 2>/dev/null)
                stages_enabled=$(jq -r '[.stages[] | select(.enabled == true) | .id] | join(" → ")' "$f" 2>/dev/null)
                gate_count=$(jq '[.stages[] | select(.gate == "approve" and .enabled == true)] | length' "$f" 2>/dev/null)
                echo -e "  ${CYAN}${BOLD}$name${RESET}"
                echo -e "    $desc"
                echo -e "    ${DIM}$stages_enabled${RESET}"
                echo -e "    ${DIM}(${gate_count} approval gates)${RESET}"
                echo ""
            done
        fi
    done

    if [[ "$found" != "true" ]]; then
        warn "No pipeline templates found."
        echo -e "  Expected at: ${DIM}templates/pipelines/*.json${RESET}"
    fi
}

pipeline_show() {
    local name="${PIPELINE_NAME_ARG:-$PIPELINE_NAME}"

    local config_file
    config_file=$(find_pipeline_config "$name") || {
        error "Pipeline template not found: $name"
        echo -e "  Available: ${DIM}shipwright pipeline list${RESET}"
        exit 1
    }

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Pipeline: $(jq -r '.name' "$config_file") ━━━${RESET}"
    echo -e "  $(jq -r '.description' "$config_file")"
    echo ""

    echo -e "${BOLD}  Defaults:${RESET}"
    jq -r '.defaults | to_entries[] | "    \(.key): \(.value)"' "$config_file" 2>/dev/null
    echo ""

    echo -e "${BOLD}  Stages:${RESET}"
    jq -r '.stages[] |
        (if .enabled then "    ✓" else "    ○" end) +
        " \(.id)" +
        (if .gate == "approve" then "  [gate: approve]" elif .gate == "skip" then "  [skip]" else "" end)
    ' "$config_file" 2>/dev/null
    echo ""

    echo -e "${BOLD}  GitHub Integration:${RESET}"
    echo -e "    • Issue: self-assign, label lifecycle, progress comments"
    echo -e "    • PR: labels, milestone, reviewers auto-propagated"
    echo -e "    • Validation: auto-close issue on completion"
    echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)          pipeline_start ;;
    resume)         pipeline_resume ;;
    status)         pipeline_status ;;
    abort)          pipeline_abort ;;
    list)           pipeline_list ;;
    show)           pipeline_show ;;
    test)
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        exec "$SCRIPT_DIR/sw-pipeline-test.sh" "$@"
        ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown pipeline command: $SUBCOMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
