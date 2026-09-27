#!/usr/bin/env bash
# shellcheck disable=SC2034  # config vars used by sourced scripts and subshells
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline — Autonomous Feature Delivery (Idea → Production)        ║
# ║  Full GitHub integration · Auto-detection · Task tracking · Metrics    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running plan/design/review stages
trap '' HUP
trap '' SIGPIPE

VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Fallbacks when helpers not loaded (e.g. test env with overridden SCRIPT_DIR)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
# Policy + pipeline quality thresholds (config/policy.json via lib/pipeline-quality.sh)
[[ -f "$SCRIPT_DIR/lib/pipeline-quality.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality.sh"
# shellcheck source=lib/pipeline-state.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-state.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-state.sh"
# shellcheck source=lib/pipeline-github.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-github.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-github.sh"
# shellcheck source=lib/pipeline-detection.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-detection.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-detection.sh"
# Adaptive Stage Timeout Engine (optional)
# shellcheck source=lib/adaptive-timeout.sh
[[ -f "$SCRIPT_DIR/lib/adaptive-timeout.sh" ]] && source "$SCRIPT_DIR/lib/adaptive-timeout.sh" 2>/dev/null || true
# shellcheck source=lib/pipeline-quality-checks.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-quality-checks.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-quality-checks.sh"
# shellcheck source=lib/pipeline-intelligence.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-intelligence.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-intelligence.sh"
# shellcheck source=lib/pipeline-stages.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-stages.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-stages.sh"
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
# Root cause classifier for failure analysis and platform issue auto-creation
# shellcheck source=lib/root-cause.sh
[[ -f "$SCRIPT_DIR/lib/root-cause.sh" ]] && source "$SCRIPT_DIR/lib/root-cause.sh" 2>/dev/null || true
PIPELINE_COVERAGE_THRESHOLD="${PIPELINE_COVERAGE_THRESHOLD:-60}"
PIPELINE_QUALITY_GATE_THRESHOLD="${PIPELINE_QUALITY_GATE_THRESHOLD:-70}"

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

# ─── Memory, Optimization & Discovery (optional) ─────────────────────────
# shellcheck source=sw-memory.sh
if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
    source "$SCRIPT_DIR/sw-memory.sh"
fi
# shellcheck source=sw-self-optimize.sh
if [[ -f "$SCRIPT_DIR/sw-self-optimize.sh" ]]; then
    source "$SCRIPT_DIR/sw-self-optimize.sh"
fi
# shellcheck source=sw-discovery.sh
if [[ -f "$SCRIPT_DIR/sw-discovery.sh" ]]; then
    source "$SCRIPT_DIR/sw-discovery.sh"
fi
# shellcheck source=sw-durable.sh
if [[ -f "$SCRIPT_DIR/sw-durable.sh" ]]; then
    source "$SCRIPT_DIR/sw-durable.sh"
fi
# shellcheck source=sw-db.sh
# for db_save_checkpoint/db_load_checkpoint (durable workflows)
[[ -f "$SCRIPT_DIR/sw-db.sh" ]] && source "$SCRIPT_DIR/sw-db.sh"
# Ensure DB schema exists so emit_event → db_add_event can write rows (CREATE IF NOT EXISTS is idempotent)
if type init_schema >/dev/null 2>&1 && type check_sqlite3 >/dev/null 2>&1 && check_sqlite3 2>/dev/null; then
    init_schema 2>/dev/null || true
fi
# shellcheck source=sw-cost.sh
# for cost_record persistence to costs.json + DB
[[ -f "$SCRIPT_DIR/sw-cost.sh" ]] && source "$SCRIPT_DIR/sw-cost.sh"
# shellcheck source=lib/cost-optimizer.sh
# for dynamic cost-performance pipeline optimization (budget checks, reductions, burst mode)
[[ -f "$SCRIPT_DIR/lib/cost-optimizer.sh" ]] && source "$SCRIPT_DIR/lib/cost-optimizer.sh"
# shellcheck source=lib/skill-registry.sh
# for skill_analyze_outcome (AI outcome learning)
[[ -f "$SCRIPT_DIR/lib/skill-registry.sh" ]] && source "$SCRIPT_DIR/lib/skill-registry.sh"
# shellcheck source=lib/skill-memory.sh
# for skill memory operations
[[ -f "$SCRIPT_DIR/lib/skill-memory.sh" ]] && source "$SCRIPT_DIR/lib/skill-memory.sh"

# ─── GitHub API Modules (optional) ─────────────────────────────────────────
# shellcheck source=sw-github-graphql.sh
[[ -f "$SCRIPT_DIR/sw-github-graphql.sh" ]] && source "$SCRIPT_DIR/sw-github-graphql.sh"
# shellcheck source=sw-github-checks.sh
[[ -f "$SCRIPT_DIR/sw-github-checks.sh" ]] && source "$SCRIPT_DIR/sw-github-checks.sh"
# shellcheck source=sw-github-deploy.sh
[[ -f "$SCRIPT_DIR/sw-github-deploy.sh" ]] && source "$SCRIPT_DIR/sw-github-deploy.sh"

# ─── Pipeline Decomposed Modules ────────────────────────────────────────────
# shellcheck source=lib/pipeline-cli.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-cli.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-cli.sh"
# Budget-aware template selection (requires helpers and compat already sourced)
# shellcheck source=lib/budget-template.sh
[[ -f "$SCRIPT_DIR/lib/budget-template.sh" ]] && source "$SCRIPT_DIR/lib/budget-template.sh"
# shellcheck source=lib/pipeline-util.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-util.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-util.sh"
# shellcheck source=lib/pipeline-execution.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-execution.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-execution.sh"
# shellcheck source=lib/pipeline-commands.sh
[[ -f "$SCRIPT_DIR/lib/pipeline-commands.sh" ]] && source "$SCRIPT_DIR/lib/pipeline-commands.sh"

# ─── Defaults ───────────────────────────────────────────────────────────────
GOAL=""
ISSUE_NUMBER=""
PIPELINE_NAME="standard"
PIPELINE_NAME_EXPLICIT=false
PIPELINE_CONFIG=""
TEST_CMD=""
MODEL=""
AGENTS=""
PIPELINE_AGENT_ID="${PIPELINE_AGENT_ID:-pipeline-$$}"
SKIP_GATES=false
HEADLESS=false
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
RESUME_FROM_CHECKPOINT=false
MAX_ITERATIONS_OVERRIDE=""
MAX_RESTARTS_OVERRIDE=""
FAST_TEST_CMD_OVERRIDE=""
PR_NUMBER=""
AUTO_WORKTREE=false
WORKTREE_NAME=""
CLEANUP_WORKTREE=false
ORIGINAL_REPO_DIR=""
REPO_OVERRIDE=""
_cleanup_done=""
PIPELINE_EXIT_CODE=1  # assume failure until run_pipeline succeeds
EFFORT_LEVEL_OVERRIDE="${SW_EFFORT_LEVEL:-}"
PIPELINE_FALLBACK_MODEL="${SW_FALLBACK_MODEL:-sonnet}"

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
PIPELINE_STAGES_PASSED=""
PIPELINE_SLOWEST_STAGE=""
LAST_STAGE_ERROR_CLASS=""
LAST_STAGE_ERROR=""

PROJECT_ROOT=""
STATE_DIR=""
STATE_FILE=""
ARTIFACTS_DIR=""
TASKS_FILE=""

CURRENT_STAGE_ID=""

# Notification / webhook
SLACK_WEBHOOK=""
NOTIFICATION_ENABLED=false

# Placeholder to accumulate input/output tokens from all pipeline stages
TOTAL_INPUT_TOKENS=0
TOTAL_OUTPUT_TOKENS=0

# Build-test retry limit (configurable via --self-heal)
BUILD_TEST_RETRIES="${BUILD_TEST_RETRIES:-2}"

# TDD mode flag (enable via --tdd or pipeline template)
TDD_ENABLED=false
PIPELINE_TDD=false

# ─── Argument Parsing (BEFORE other setup) ─────────────────────────────────
SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

PIPELINE_NAME_ARG=""
parse_args "$@"

# Export effort and fallback variables so subprocesses can access them
export EFFORT_LEVEL_OVERRIDE PIPELINE_FALLBACK_MODEL

# ─── Detach Mode ──────────────────────────────────────────────────────────────
# --worktree auto-detaches unless --foreground explicitly overrides
if [[ -z "${DETACH:-}" ]]; then
    # No explicit flag — auto-detach for worktree pipelines
    if [[ "${AUTO_WORKTREE:-}" == "true" ]]; then
        DETACH=true
    else
        DETACH=false
    fi
fi

# ─── Non-Interactive Detection ──────────────────────────────────────────────
# When stdin is not a terminal (background, pipe, nohup, tmux send-keys),
# auto-enable headless mode to prevent read prompts from killing the script.
if [[ ! -t 0 ]]; then
    HEADLESS=true
    if [[ "$SKIP_GATES" != "true" ]]; then
        SKIP_GATES=true
    fi
fi
# --worktree implies headless when stdin is not a terminal
if [[ "$AUTO_WORKTREE" == "true" && "$SKIP_GATES" != "true" && ! -t 0 ]]; then
    SKIP_GATES=true
fi

# ─── Main ───────────────────────────────────────────────────────────────────

case "$SUBCOMMAND" in
    start)          pipeline_start ;;
    resume)         pipeline_resume ;;
    status)         pipeline_status ;;
    abort)          pipeline_abort ;;
    list)           pipeline_list ;;
    show)           pipeline_show ;;
    attach)         pipeline_attach "${ISSUE_NUMBER:-${2:-}}" ;;
    tail|logs)      pipeline_tail "${ISSUE_NUMBER:-${2:-}}" ;;
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
