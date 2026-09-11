#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop — Continuous agent loop harness for Claude Code               ║
# ║                                                                         ║
# ║  Runs Claude Code in a headless loop until a goal is achieved.          ║
# ║  Supports single-agent and multi-agent (parallel worktree) modes.       ║
# ║                                                                         ║
# ║  Inspired by Anthropic's autonomous 16-agent C compiler build.          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# Allow spawning Claude CLI from within a Claude Code session (daemon, fleet, etc.)
unset CLAUDECODE 2>/dev/null || true
# Ignore SIGHUP so tmux attach/detach doesn't kill long-running agent sessions
trap '' HUP
trap '' SIGPIPE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"
# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && source "$SCRIPT_DIR/lib/config.sh"
# Source DB for dual-write (emit_event → JSONL + SQLite).
# Note: do NOT call init_schema here — the pipeline (sw-pipeline.sh) owns schema
# initialization. Calling it here would create an empty DB that shadows JSON cost data.
if [[ -f "$SCRIPT_DIR/sw-db.sh" ]]; then
    source "$SCRIPT_DIR/sw-db.sh" 2>/dev/null || true
fi
# Cross-pipeline discovery (learnings from other pipeline runs)
[[ -f "$SCRIPT_DIR/sw-discovery.sh" ]] && source "$SCRIPT_DIR/sw-discovery.sh" 2>/dev/null || true
# Source loop sub-modules for modular iteration management
[[ -f "$SCRIPT_DIR/lib/loop-iteration.sh" ]] && source "$SCRIPT_DIR/lib/loop-iteration.sh"
[[ -f "$SCRIPT_DIR/lib/loop-convergence.sh" ]] && source "$SCRIPT_DIR/lib/loop-convergence.sh"
[[ -f "$SCRIPT_DIR/lib/loop-restart.sh" ]] && source "$SCRIPT_DIR/lib/loop-restart.sh"
[[ -f "$SCRIPT_DIR/lib/loop-progress.sh" ]] && source "$SCRIPT_DIR/lib/loop-progress.sh"
# Intelligent session restart with enhanced briefings and cross-session tracking
[[ -f "$SCRIPT_DIR/lib/session-restart.sh" ]] && source "$SCRIPT_DIR/lib/session-restart.sh"
# Context window budget monitoring (issue #209)
# shellcheck source=lib/context-budget.sh
[[ -f "$SCRIPT_DIR/lib/context-budget.sh" ]] && source "$SCRIPT_DIR/lib/context-budget.sh" 2>/dev/null || true
# Convergence detection and scoring (issue #203)
[[ -f "$SCRIPT_DIR/lib/convergence.sh" ]] && source "$SCRIPT_DIR/lib/convergence.sh" 2>/dev/null || true
# Error actionability scoring and enhancement for better error context
# shellcheck source=lib/error-actionability.sh
[[ -f "$SCRIPT_DIR/lib/error-actionability.sh" ]] && source "$SCRIPT_DIR/lib/error-actionability.sh" 2>/dev/null || true
# Autonomous error recovery with model escalation
# shellcheck source=lib/auto-recovery.sh
[[ -f "$SCRIPT_DIR/lib/auto-recovery.sh" ]] && source "$SCRIPT_DIR/lib/auto-recovery.sh" 2>/dev/null || true
# Test execution optimization (issue #200)
# shellcheck source=lib/test-optimizer.sh
[[ -f "$SCRIPT_DIR/lib/test-optimizer.sh" ]] && source "$SCRIPT_DIR/lib/test-optimizer.sh" 2>/dev/null || true
# Audit trail for compliance-grade pipeline traceability
# shellcheck source=lib/audit-trail.sh
[[ -f "$SCRIPT_DIR/lib/audit-trail.sh" ]] && source "$SCRIPT_DIR/lib/audit-trail.sh" 2>/dev/null || true
# Process reward model for per-step iteration scoring (Phase 3)
# shellcheck source=lib/process-reward.sh
[[ -f "$SCRIPT_DIR/lib/process-reward.sh" ]] && source "$SCRIPT_DIR/lib/process-reward.sh" 2>/dev/null || true
# Cross-session reinforcement learning optimizer (Phase 7)
# shellcheck source=lib/rl-optimizer.sh
[[ -f "$SCRIPT_DIR/lib/rl-optimizer.sh" ]] && source "$SCRIPT_DIR/lib/rl-optimizer.sh" 2>/dev/null || true
# Autoresearch RL modules (Phase 8): reward aggregation, bandit selection, policy learning
[[ -f "$SCRIPT_DIR/lib/reward-aggregator.sh" ]] && source "$SCRIPT_DIR/lib/reward-aggregator.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/bandit-selector.sh" ]] && source "$SCRIPT_DIR/lib/bandit-selector.sh" 2>/dev/null || true
[[ -f "$SCRIPT_DIR/lib/policy-learner.sh" ]] && source "$SCRIPT_DIR/lib/policy-learner.sh" 2>/dev/null || true
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
    # shellcheck disable=SC2155
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────
GOAL=""
ORIGINAL_GOAL=""  # Preserved across restarts — GOAL gets appended to
MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"
TEST_CMD=""
FAST_TEST_CMD=""
FAST_TEST_INTERVAL=5
TEST_LOG_FILE=""
MODEL="${SW_MODEL:-opus}"
AGENTS=1
AGENT_ROLES=""
USE_WORKTREE=false
SKIP_PERMISSIONS=false
MAX_TURNS=""
RESUME=false
VERBOSE=false
MAX_ITERATIONS_EXPLICIT=false
MAX_RESTARTS=$(_config_get_int "loop.max_restarts" 0 2>/dev/null || echo 0)
SESSION_RESTART=false
RESTART_COUNT=0
REPO_OVERRIDE=""
VERSION="3.3.0"

# ─── Token Tracking ─────────────────────────────────────────────────────────
LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
LOOP_COST_MILLICENTS=0

# ─── Flexible Iteration Defaults (all config-driven) ───────────────────────
AUTO_EXTEND=true
EXTENSION_SIZE=$(_smart_int "loop.extension_size" 5)
MAX_EXTENSIONS=$(_smart_int "loop.max_extensions" 3)
EXTENSION_COUNT=0

# ─── Circuit Breaker Defaults (config-driven) ─────────────────────────────
CIRCUIT_BREAKER_THRESHOLD=$(_smart_int "loop.circuit_breaker_threshold" 3)
MIN_PROGRESS_LINES=$(_smart_int "loop.min_progress_lines" 5)

# ─── Context Exhaustion Recovery ────────────────────────────────────────────────
CONTEXT_EXHAUSTION_PATTERNS="context.length.exceeded|maximum context length|context_length_exceeded|prompt is too long"
CONTEXT_RESTART_COUNT=0
CONTEXT_RESTART_LIMIT=$(_smart_int "loop.context_restart_limit" 2)

# ─── Session Continuity ──────────────────────────────────────────────────────
# Each iteration currently starts a COLD Claude session: the prompt is
# recomposed from scratch and the cache is written again rather than read.
# Passing one --session-id across iterations lets them continue a single
# conversation instead.
#
# Off by default. This changes conversation semantics — the model carries prior
# turns rather than being re-briefed from progress.md — so it wants a measured
# rollout (compare `shipwright cost show` with it on and off) rather than being
# switched on for every existing pipeline at once. Enable with
# `--session-continuity`, LOOP_SESSION_CONTINUITY=1, or loop.session_continuity
# in config.
#
# LOOP_SESSION_ID stays EMPTY when disabled; build_claude_flags keys off that,
# so the flag is simply absent in the default path.
SESSION_CONTINUITY="${LOOP_SESSION_CONTINUITY:-$(_config_get_int "loop.session_continuity" 0 2>/dev/null || echo 0)}"
[[ "$SESSION_CONTINUITY" == "true" ]] && SESSION_CONTINUITY=1
LOOP_SESSION_ID=""

# ─── Audit & Quality Gate Defaults ───────────────────────────────────────────
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
DOD_FILE=""
QUALITY_GATES_ENABLED=false
AUDIT_RESULT=""
# Consecutive iterations where the auditor process itself failed to run.
# Fail-open is bounded by AUDIT_UNAVAILABLE_LIMIT so a permanently broken
# auditor cannot silently wave every iteration through the completion gate.
AUDIT_UNAVAILABLE_STREAK=0
AUDIT_UNAVAILABLE_LIMIT="${LOOP_AUDIT_UNAVAILABLE_LIMIT:-2}"
COMPLETION_REJECTED=false
QUALITY_GATE_PASSED=true

# ─── Multi-Test Defaults ──────────────────────────────────────────────────
ADDITIONAL_TEST_CMDS=()   # Array of extra test commands (from --additional-test-cmds)

# ─── Context Budget ──────────────────────────────────────────────────────────
CONTEXT_BUDGET_CHARS="${CONTEXT_BUDGET_CHARS:-200000}"  # Max prompt chars before trimming

# ─── Claude CLI Flags ─────────────────────────────────────────────────────────
EFFORT_LEVEL="${SW_EFFORT_LEVEL:-}"
FALLBACK_MODEL="${SW_FALLBACK_MODEL:-}"  # Empty = no fallback flag (intelligent default)

# ─── Parse Arguments ──────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright loop${RESET} \"<goal>\" [options]"
    echo ""
    echo -e "${BOLD}OPTIONS${RESET}"
    echo -e "  ${CYAN}--repo <path>${RESET}             Change to directory before running (must be a git repo)"
    echo -e "  ${CYAN}--local${RESET}                   Disable GitHub operations (local-only mode)"
    echo -e "  ${CYAN}--max-iterations${RESET} N       Max loop iterations (default: 20)"
    echo -e "  ${CYAN}--test-cmd${RESET} \"cmd\"         Test command to run between iterations"
    echo -e "  ${CYAN}--fast-test-cmd${RESET} \"cmd\"      Fast/subset test command (alternates with full)"
    echo -e "  ${CYAN}--fast-test-interval${RESET} N       Run full tests every N iterations (default: 5)"
    echo -e "  ${CYAN}--additional-test-cmds${RESET} \"cmd\" Extra test command (repeatable)"
    echo -e "  ${CYAN}--model${RESET} MODEL             Claude model to use (default: opus)"
    echo -e "  ${CYAN}--effort${RESET} low|medium|high   Effort level for Claude reasoning (default: auto per stage)"
    echo -e "  ${CYAN}--fallback-model${RESET} MODEL      Fallback model on rate limits (default: sonnet)"
    echo -e "  ${CYAN}--agents${RESET} N                Number of parallel agents (default: 1)"
    echo -e "  ${CYAN}--roles${RESET} \"r1,r2,...\"        Role per agent: builder,reviewer,tester,optimizer,docs,security"
    echo -e "  ${CYAN}--worktree${RESET}                Use git worktrees for isolation (auto if agents > 1)"
    echo -e "  ${CYAN}--skip-permissions${RESET}        Pass --dangerously-skip-permissions to Claude"
    echo -e "  ${CYAN}--max-turns${RESET} N             Max API turns per Claude session"
    echo -e "  ${CYAN}--resume${RESET}                  Resume from existing .claude/loop-state.md"
    echo -e "  ${CYAN}--max-restarts${RESET} N          Max session restarts on exhaustion (default: 0)"
    echo -e "  ${CYAN}--verbose${RESET}                 Show full Claude output (default: summary)"
    echo -e "  ${CYAN}--help${RESET}                    Show this help"
    echo ""
    echo -e "${BOLD}AUDIT & QUALITY${RESET}"
    echo -e "  ${CYAN}--audit${RESET}                   Inject self-audit checklist into agent prompt"
    echo -e "  ${CYAN}--audit-agent${RESET}             Run separate auditor agent (haiku) after each iteration"
    echo -e "  ${CYAN}--quality-gates${RESET}           Enable automated quality gates before accepting completion"
    echo -e "  ${CYAN}--definition-of-done${RESET} FILE DoD checklist file — evaluated by AI against git diff"
    echo -e "  ${CYAN}--no-auto-extend${RESET}          Disable auto-extension when max iterations reached"
    echo -e "  ${CYAN}--extension-size${RESET} N         Additional iterations per extension (default: 5)"
    echo -e "  ${CYAN}--max-extensions${RESET} N         Max number of auto-extensions (default: 3)"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add payment processing\" --test-cmd \"npm test\" --max-iterations 30${RESET}"
    echo -e "  ${DIM}shipwright loop \"Refactor the database layer\" --agents 3 --model sonnet${RESET}"
    echo -e "  ${DIM}shipwright loop \"Fix all lint errors\" --skip-permissions --verbose${RESET}"
    echo -e "  ${DIM}shipwright loop \"Add auth\" --audit --audit-agent --quality-gates${RESET}"
    echo -e "  ${DIM}shipwright loop \"Ship feature\" --quality-gates --definition-of-done dod.md${RESET}"
    echo ""
    echo -e "${BOLD}COMPLETION & CIRCUIT BREAKER${RESET}"
    echo -e "  The loop completes when:"
    echo -e "  ${DIM}• Claude outputs LOOP_COMPLETE and all quality gates pass${RESET}"
    echo -e "  ${DIM}• Max iterations reached (auto-extends if work is incomplete)${RESET}"
    echo -e "  The loop stops (circuit breaker) if:"
    echo -e "  ${DIM}• ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with < ${MIN_PROGRESS_LINES} lines changed${RESET}"
    echo -e "  ${DIM}• Hard cap reached (max_iterations + max_extensions * extension_size)${RESET}"
    echo -e "  ${DIM}• Ctrl-C (graceful shutdown with summary)${RESET}"
    echo ""
    echo -e "${BOLD}STATE & LOGS${RESET}"
    echo -e "  ${DIM}State file:  .claude/loop-state.md${RESET}"
    echo -e "  ${DIM}Logs dir:    .claude/loop-logs/${RESET}"
    echo -e "  ${DIM}Resume:      shipwright loop --resume${RESET}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            REPO_OVERRIDE="${2:-}"
            [[ -z "$REPO_OVERRIDE" ]] && { error "Missing value for --repo"; exit 1; }
            shift 2
            ;;
        --repo=*) REPO_OVERRIDE="${1#--repo=}"; shift ;;
        --local)
            # Skip GitHub operations in loop
            export NO_GITHUB=true
            shift ;;
        --max-iterations)
            MAX_ITERATIONS="${2:-}"
            MAX_ITERATIONS_EXPLICIT=true
            [[ -z "$MAX_ITERATIONS" ]] && { error "Missing value for --max-iterations"; exit 1; }
            shift 2
            ;;
        --max-iterations=*) MAX_ITERATIONS="${1#--max-iterations=}"; MAX_ITERATIONS_EXPLICIT=true; shift ;;
        --test-cmd)
            TEST_CMD="${2:-}"
            [[ -z "$TEST_CMD" ]] && { error "Missing value for --test-cmd"; exit 1; }
            shift 2
            ;;
        --test-cmd=*) TEST_CMD="${1#--test-cmd=}"; shift ;;
        --model)
            MODEL="${2:-}"
            [[ -z "$MODEL" ]] && { error "Missing value for --model"; exit 1; }
            shift 2
            ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --effort)
            EFFORT_LEVEL="${2:-}"
            [[ -z "$EFFORT_LEVEL" ]] && { error "Missing value for --effort"; exit 1; }
            shift 2
            ;;
        --effort=*) EFFORT_LEVEL="${1#--effort=}"; shift ;;
        --fallback-model)
            FALLBACK_MODEL="${2:-}"
            [[ -z "$FALLBACK_MODEL" ]] && { error "Missing value for --fallback-model"; exit 1; }
            shift 2
            ;;
        --fallback-model=*) FALLBACK_MODEL="${1#--fallback-model=}"; shift ;;
        --agents)
            AGENTS="${2:-}"
            [[ -z "$AGENTS" ]] && { error "Missing value for --agents"; exit 1; }
            shift 2
            ;;
        --agents=*) AGENTS="${1#--agents=}"; shift ;;
        --worktree) USE_WORKTREE=true; shift ;;
        --skip-permissions) SKIP_PERMISSIONS=true; shift ;;
        --max-turns)
            MAX_TURNS="${2:-}"
            [[ -z "$MAX_TURNS" ]] && { error "Missing value for --max-turns"; exit 1; }
            shift 2
            ;;
        --max-turns=*) MAX_TURNS="${1#--max-turns=}"; shift ;;
        --resume) RESUME=true; shift ;;
        # NOTE: --resume above is shipwright's own (re-read .claude/loop-state.md).
        # This is different: it continues one *Claude* session across iterations.
        --session-continuity) SESSION_CONTINUITY=1; shift ;;
        --no-session-continuity) SESSION_CONTINUITY=0; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --audit) AUDIT_ENABLED=true; shift ;;
        --audit-agent) AUDIT_AGENT_ENABLED=true; shift ;;
        --definition-of-done)
            DOD_FILE="${2:-}"
            [[ -z "$DOD_FILE" ]] && { error "Missing value for --definition-of-done"; exit 1; }
            shift 2
            ;;
        --definition-of-done=*) DOD_FILE="${1#--definition-of-done=}"; shift ;;
        --quality-gates) QUALITY_GATES_ENABLED=true; shift ;;
        --no-auto-extend) AUTO_EXTEND=false; shift ;;
        --extension-size)
            EXTENSION_SIZE="${2:-}"
            [[ -z "$EXTENSION_SIZE" ]] && { error "Missing value for --extension-size"; exit 1; }
            shift 2
            ;;
        --extension-size=*) EXTENSION_SIZE="${1#--extension-size=}"; shift ;;
        --max-extensions)
            MAX_EXTENSIONS="${2:-}"
            [[ -z "$MAX_EXTENSIONS" ]] && { error "Missing value for --max-extensions"; exit 1; }
            shift 2
            ;;
        --max-extensions=*) MAX_EXTENSIONS="${1#--max-extensions=}"; shift ;;
        --fast-test-cmd)
            FAST_TEST_CMD="${2:-}"
            [[ -z "$FAST_TEST_CMD" ]] && { error "Missing value for --fast-test-cmd"; exit 1; }
            shift 2
            ;;
        --fast-test-cmd=*) FAST_TEST_CMD="${1#--fast-test-cmd=}"; shift ;;
        --fast-test-interval)
            FAST_TEST_INTERVAL="${2:-}"
            [[ -z "$FAST_TEST_INTERVAL" ]] && { error "Missing value for --fast-test-interval"; exit 1; }
            shift 2
            ;;
        --fast-test-interval=*) FAST_TEST_INTERVAL="${1#--fast-test-interval=}"; shift ;;
        --additional-test-cmds)
            ADDITIONAL_TEST_CMDS+=("${2:-}")
            [[ -z "${2:-}" ]] && { error "Missing value for --additional-test-cmds"; exit 1; }
            shift 2
            ;;
        --additional-test-cmds=*) ADDITIONAL_TEST_CMDS+=("${1#--additional-test-cmds=}"); shift ;;
        --max-restarts)
            MAX_RESTARTS="${2:-}"
            [[ -z "$MAX_RESTARTS" ]] && { error "Missing value for --max-restarts"; exit 1; }
            shift 2
            ;;
        --max-restarts=*) MAX_RESTARTS="${1#--max-restarts=}"; shift ;;
        --roles)
            AGENT_ROLES="${2:-}"
            [[ -z "$AGENT_ROLES" ]] && { error "Missing value for --roles"; exit 1; }
            shift 2
            ;;
        --roles=*) AGENT_ROLES="${1#--roles=}"; shift ;;
        --help|-h)
            show_help
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            echo ""
            show_help
            exit 1
            ;;
        *)
            # Positional: goal
            if [[ -z "$GOAL" ]]; then
                GOAL="$1"
            else
                error "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Auto-enable worktree for multi-agent
if [[ "$AGENTS" -gt 1 ]]; then
    # shellcheck disable=SC2034
    USE_WORKTREE=true
fi

# Recruit-powered auto-role assignment when multi-agent but no roles specified
if [[ "$AGENTS" -gt 1 ]] && [[ -z "$AGENT_ROLES" ]] && [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
    _recruit_goal="${GOAL:-}"
    if [[ -n "$_recruit_goal" ]]; then
        _recruit_team=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$_recruit_goal" 2>/dev/null) || true
        if [[ -n "$_recruit_team" ]]; then
            _recruit_roles=$(echo "$_recruit_team" | jq -r '.team | join(",")' 2>/dev/null) || true
            if [[ -n "$_recruit_roles" && "$_recruit_roles" != "null" ]]; then
                AGENT_ROLES="$_recruit_roles"
                info "Recruit assigned roles: ${AGENT_ROLES}"
            fi
        fi
    fi
fi

# Warn if --roles without --agents
if [[ -n "$AGENT_ROLES" ]] && [[ "$AGENTS" -le 1 ]]; then
    warn "--roles requires --agents > 1 (roles are ignored in single-agent mode)"
fi

# max-restarts is supported in both single-agent and multi-agent mode
# In multi-agent mode, restarts apply per-agent (agent can be respawned up to MAX_RESTARTS)

# Validate numeric flags
if ! [[ "$FAST_TEST_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
    error "--fast-test-interval must be a positive integer (got: $FAST_TEST_INTERVAL)"
    exit 1
fi
if ! [[ "$MAX_RESTARTS" =~ ^[0-9]+$ ]]; then
    error "--max-restarts must be a non-negative integer (got: $MAX_RESTARTS)"
    exit 1
fi

# Validate effort level
if [[ -n "$EFFORT_LEVEL" ]] && [[ "$EFFORT_LEVEL" != "low" && "$EFFORT_LEVEL" != "medium" && "$EFFORT_LEVEL" != "high" ]]; then
    error "--effort must be low, medium, or high (got: $EFFORT_LEVEL)"
    exit 1
fi

# ─── Validate Inputs ─────────────────────────────────────────────────────────

if ! $RESUME && [[ -z "$GOAL" ]]; then
    error "Missing goal. Usage: shipwright loop \"<goal>\" [options]"
    echo ""
    echo -e "  ${DIM}shipwright loop \"Build user auth with JWT\"${RESET}"
    echo -e "  ${DIM}shipwright loop --resume${RESET}"
    exit 1
fi

# Handle --repo flag: change to directory before running
if [[ -n "$REPO_OVERRIDE" ]]; then
    if [[ ! -d "$REPO_OVERRIDE" ]]; then
        error "Directory does not exist: $REPO_OVERRIDE"
        exit 1
    fi
    if ! cd "$REPO_OVERRIDE" 2>/dev/null; then
        error "Cannot cd to: $REPO_OVERRIDE"
        exit 1
    fi
    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        error "Not a git repository: $REPO_OVERRIDE"
        exit 1
    fi
    info "Using repository: $(pwd)"
fi

if ! command -v claude >/dev/null 2>&1; then
    error "Claude Code CLI not found. Install it first:"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    error "Not inside a git repository. The loop requires git for progress tracking."
    exit 1
fi

# Preserve original goal before any appending (memory fixes, human feedback)
ORIGINAL_GOAL="$GOAL"

# ─── Timeout Detection ────────────────────────────────────────────────────────
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_CMD="gtimeout"
fi
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-$(_config_get_int "loop.claude_timeout" 1800 2>/dev/null || echo 1800)}"  # 30 min default

if [[ "$AGENTS" -gt 1 ]]; then
    if ! command -v tmux >/dev/null 2>&1; then
        error "tmux is required for multi-agent mode."
        echo -e "  ${DIM}brew install tmux${RESET}  (macOS)"
        exit 1
    fi
    if [[ -z "${TMUX:-}" ]]; then
        error "Multi-agent mode requires running inside tmux."
        echo -e "  ${DIM}tmux new -s work${RESET}"
        exit 1
    fi
fi

# ─── Directory Setup ─────────────────────────────────────────────────────────

PROJECT_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$PROJECT_ROOT/.claude"
STATE_FILE="$STATE_DIR/loop-state.md"
LOG_DIR="$STATE_DIR/loop-logs"
WORKTREE_DIR="$PROJECT_ROOT/.worktrees"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ─── Context Budget Initialization ────────────────────────────────────────────
# Initialize context window budget tracker (issue #209)
ARTIFACTS_DIR="${STATE_DIR}/pipeline-artifacts"
mkdir -p "$ARTIFACTS_DIR"
if type context_budget_init >/dev/null 2>&1; then
    # Set total budget (default 800K, configurable via env/config)
    CONTEXT_BUDGET="${CONTEXT_BUDGET_TOKENS:-800000}"
    context_budget_init "$CONTEXT_BUDGET" "$ARTIFACTS_DIR" 2>/dev/null || true
fi

# ─── Adaptive Model Selection ────────────────────────────────────────────────
# Uses intelligence engine when available, falls back to defaults.
select_adaptive_model() {
    local role="${1:-build}"
    local default_model="${2:-opus}"
    # If user explicitly set --model, respect it
    if [[ "$default_model" != "${SW_MODEL:-opus}" ]]; then
        echo "$default_model"
        return 0
    fi
    # Read learned model routing
    local _routing_file="${HOME}/.shipwright/optimization/model-routing.json"
    if [[ -f "$_routing_file" ]] && command -v jq >/dev/null 2>&1; then
        local _routed_model
        _routed_model=$(jq -r --arg r "$role" '.routes[$r].model // ""' "$_routing_file" 2>/dev/null) || true
        if [[ -n "${_routed_model:-}" && "${_routed_model:-}" != "null" ]]; then
            echo "${_routed_model}"
            return 0
        fi
    fi

    # Try intelligence-based recommendation
    if type intelligence_recommend_model >/dev/null 2>&1; then
        local rec
        rec=$(intelligence_recommend_model "$role" "${COMPLEXITY:-5}" "${BUDGET:-0}" 2>/dev/null || echo "")
        if [[ -n "$rec" ]]; then
            local recommended
            recommended=$(echo "$rec" | jq -r '.model // ""' 2>/dev/null || echo "")
            if [[ -n "$recommended" && "$recommended" != "null" ]]; then
                echo "$recommended"
                return 0
            fi
        fi
    fi
    echo "$default_model"
}

# Select audit/DoD model — uses haiku if success rate is high enough, else sonnet
select_audit_model() {
    local default_model
    default_model=$(_smart_model "audit" "haiku")
    local opt_file="$HOME/.shipwright/optimization/audit-tuning.json"
    if [[ -f "$opt_file" ]] && command -v jq >/dev/null 2>&1; then
        local success_rate
        success_rate=$(jq -r '.haiku_success_rate // 100' "$opt_file" 2>/dev/null || echo "100")
        if [[ "${success_rate%%.*}" -lt 90 ]]; then
            echo "sonnet"
            return 0
        fi
    fi
    echo "$default_model"
}

# ─── Token Accumulation ─────────────────────────────────────────────────────
# Parse token counts from Claude CLI JSON output and accumulate running totals.
# With --output-format json, the output is a JSON array containing a "result"
# object with usage.input_tokens, usage.output_tokens, and total_cost_usd.
accumulate_loop_tokens() {
    local log_file="$1"
    [[ ! -f "$log_file" ]] && return 0

    # If jq is available and the file looks like JSON, parse structured output
    if command -v jq >/dev/null 2>&1 && head -c1 "$log_file" 2>/dev/null | grep -q '\['; then
        local input_tok output_tok cache_read cache_create cost_usd
        # The result object is the last element in the JSON array
        input_tok=$(jq -r '.[-1].usage.input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        output_tok=$(jq -r '.[-1].usage.output_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_read=$(jq -r '.[-1].usage.cache_read_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cache_create=$(jq -r '.[-1].usage.cache_creation_input_tokens // 0' "$log_file" 2>/dev/null || echo "0")
        cost_usd=$(jq -r '.[-1].total_cost_usd // 0' "$log_file" 2>/dev/null || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
        # Accumulate cost in millicents for integer arithmetic
        if [[ -n "$cost_usd" && "$cost_usd" != "0" && "$cost_usd" != "null" ]]; then
            local cost_millicents
            cost_millicents=$(echo "$cost_usd" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        else
            # Estimate cost from tokens when Claude doesn't provide it (rates per million tokens)
            local total_in total_out
            total_in=$(( ${input_tok:-0} + ${cache_read:-0} + ${cache_create:-0} ))
            total_out=${output_tok:-0}
            local cost=0
            case "${MODEL:-${CLAUDE_MODEL:-sonnet}}" in
                *opus*)   cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 15 + o * 75) / 1000000}') ;;
                *sonnet*) cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
                *haiku*)  cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 0.25 + o * 1.25) / 1000000}') ;;
                *)       cost=$(awk -v i="$total_in" -v o="$total_out" 'BEGIN{printf "%.6f", (i * 3 + o * 15) / 1000000}') ;;
            esac
            cost_millicents=$(echo "$cost" | awk '{printf "%.0f", $1 * 100000}' 2>/dev/null || echo "0")
            LOOP_COST_MILLICENTS=$(( ${LOOP_COST_MILLICENTS:-0} + ${cost_millicents:-0} ))
        fi
    else
        # Fallback: regex-based parsing for non-JSON output
        local input_tok output_tok
        input_tok=$(grep -oE 'input[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")
        output_tok=$(grep -oE 'output[_ ]tokens?[: ]+[0-9,]+' "$log_file" 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ',' || echo "0")

        LOOP_INPUT_TOKENS=$(( LOOP_INPUT_TOKENS + ${input_tok:-0} ))
        LOOP_OUTPUT_TOKENS=$(( LOOP_OUTPUT_TOKENS + ${output_tok:-0} ))
    fi
}

# ─── JSON→Text Extraction ──────────────────────────────────────────────────
# Extract plain text from Claude's --output-format json response.
# Handles: valid JSON arrays, malformed JSON, non-JSON output, empty output.
_extract_text_from_json() {
    local json_file="$1" log_file="$2" err_file="${3:-}"

    # Case 1: File doesn't exist or is empty
    if [[ ! -s "$json_file" ]]; then
        # Check stderr for error messages
        if [[ -s "$err_file" ]]; then
            cp "$err_file" "$log_file"
        else
            echo "(no output)" > "$log_file"
        fi
        return 0
    fi

    local first_char
    first_char=$(head -c1 "$json_file" 2>/dev/null || true)

    # Case 2: Valid JSON (array or object) — extract text with jq
    if [[ ("$first_char" == "[" || "$first_char" == "{") ]] && command -v jq >/dev/null 2>&1; then
        local extracted
        if [[ "$first_char" == "[" ]]; then
            # Array: extract .result from last element
            extracted=$(jq -r '.[-1].result // empty' "$json_file" 2>/dev/null) || true
            if [[ -n "$extracted" ]]; then
                echo "$extracted" > "$log_file"
                return 0
            fi
            # Try .content fields
            extracted=$(jq -r '.[].content // empty' "$json_file" 2>/dev/null | head -500) || true
        else
            # Object: extract .result directly
            extracted=$(jq -r '.result // empty' "$json_file" 2>/dev/null) || true
            if [[ -n "$extracted" ]]; then
                echo "$extracted" > "$log_file"
                return 0
            fi
            # Try .content field
            extracted=$(jq -r '.content // empty' "$json_file" 2>/dev/null) || true
        fi
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # JSON parsed but no text found — write placeholder
        warn "JSON output has no .result field — check $json_file"
        echo "(no text result in JSON output)" > "$log_file"
        return 0
    fi

    # Case 3: Looks like JSON but jq is not available — can't parse, use raw
    if [[ "$first_char" == "[" || "$first_char" == "{" ]]; then
        warn "JSON output but jq not available — using raw output"
        cp "$json_file" "$log_file"
        return 0
    fi

    # Case 4: Not JSON at all (plain text, error message, etc.) — use as-is
    cp "$json_file" "$log_file"
    return 0
}

# Write accumulated token totals to a JSON file for the pipeline to read.
write_loop_tokens() {
    local token_file="$LOG_DIR/loop-tokens.json"
    local cost_usd="0"
    if [[ "${LOOP_COST_MILLICENTS:-0}" -gt 0 ]]; then
        cost_usd=$(awk "BEGIN {printf \"%.6f\", ${LOOP_COST_MILLICENTS} / 100000}" 2>/dev/null || echo "0")
    fi
    local tmp_file
    tmp_file=$(mktemp "${token_file}.XXXXXX" 2>/dev/null || mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN
    cat > "$tmp_file" <<TOKJSON
{"input_tokens":${LOOP_INPUT_TOKENS},"output_tokens":${LOOP_OUTPUT_TOKENS},"cost_usd":${cost_usd},"iterations":${ITERATION:-0}}
TOKJSON
    mv "$tmp_file" "$token_file"
}

# ─── Adaptive Iteration Budget ──────────────────────────────────────────────
# Reads tuning config for smarter iteration/circuit-breaker thresholds.
apply_adaptive_budget() {
    local tuning_file="$HOME/.shipwright/optimization/loop-tuning.json"
    if [[ -f "$tuning_file" ]] && command -v jq >/dev/null 2>&1; then
        local tuned_max tuned_ext tuned_ext_count tuned_cb
        tuned_max=$(jq -r '.max_iterations // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext=$(jq -r '.extension_size // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_ext_count=$(jq -r '.max_extensions // ""' "$tuning_file" 2>/dev/null || echo "")
        tuned_cb=$(jq -r '.circuit_breaker_threshold // ""' "$tuning_file" 2>/dev/null || echo "")

        # Only apply tuned values if user didn't explicitly set them
        if ! $MAX_ITERATIONS_EXPLICIT && [[ -n "$tuned_max" && "$tuned_max" != "null" ]]; then
            MAX_ITERATIONS="$tuned_max"
        fi
        [[ -n "$tuned_ext" && "$tuned_ext" != "null" ]] && EXTENSION_SIZE="$tuned_ext"
        [[ -n "$tuned_ext_count" && "$tuned_ext_count" != "null" ]] && MAX_EXTENSIONS="$tuned_ext_count"
        [[ -n "$tuned_cb" && "$tuned_cb" != "null" ]] && CIRCUIT_BREAKER_THRESHOLD="$tuned_cb"
    fi

    # Read learned iteration model
    local _iter_model="${HOME}/.shipwright/optimization/iteration-model.json"
    if [[ -f "$_iter_model" ]] && ! $MAX_ITERATIONS_EXPLICIT && command -v jq >/dev/null 2>&1; then
        local _complexity="${ISSUE_COMPLEXITY:-${COMPLEXITY:-medium}}"
        local _predicted_max
        _predicted_max=$(jq -r --arg c "$_complexity" '.predictions[$c].max_iterations // ""' "$_iter_model" 2>/dev/null) || true
        if [[ -n "${_predicted_max:-}" && "${_predicted_max:-}" != "null" && "${_predicted_max:-0}" -gt 0 ]]; then
            MAX_ITERATIONS="${_predicted_max}"
            info "Iteration model: ${_complexity} complexity → max ${_predicted_max} iterations"
        fi
    fi

    # Try intelligence-based iteration estimate
    if type intelligence_estimate_iterations >/dev/null 2>&1 && ! $MAX_ITERATIONS_EXPLICIT; then
        local est
        est=$(intelligence_estimate_iterations "${GOAL:-}" "${COMPLEXITY:-5}" 2>/dev/null || echo "")
        if [[ -n "$est" && "$est" =~ ^[0-9]+$ ]]; then
            MAX_ITERATIONS="$est"
        fi
    fi
}

# ─── Progress Velocity Tracking ─────────────────────────────────────────────
ITERATION_LINES_CHANGED=""
VELOCITY_HISTORY=""


# Compute average lines/iteration from recent history

# ─── Timing Helpers ───────────────────────────────────────────────────────────

format_duration() {
    local secs="$1"
    local mins=$(( secs / 60 ))
    local remaining_secs=$(( secs % 60 ))
    if [[ $mins -gt 0 ]]; then
        printf "%dm %ds" "$mins" "$remaining_secs"
    else
        printf "%ds" "$remaining_secs"
    fi
}

# ─── State Management ────────────────────────────────────────────────────────

ITERATION=0
CONSECUTIVE_FAILURES=0
TOTAL_COMMITS=0
START_EPOCH=""
STATUS="running"
TEST_PASSED=""
TEST_OUTPUT=""
LOG_ENTRIES=""






# ─── Semantic Validation for Claude Output ─────────────────────────────────────
# Validates changed files before commit to catch syntax errors and API error leakage.
validate_claude_output() {
    local workdir="${1:-.}"
    local issues=0

    # Check for syntax errors in changed files
    local changed_files
    changed_files=$(git -C "$workdir" diff --cached --name-only 2>/dev/null || git -C "$workdir" diff --name-only 2>/dev/null)

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        [[ ! -f "$workdir/$file" ]] && continue

        case "$file" in
            *.sh)
                if ! bash -n "$workdir/$file" 2>/dev/null; then
                    warn "Syntax error in shell script: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.py)
                if command -v python3 >/dev/null 2>&1; then
                    if ! python3 -c "import ast, sys; ast.parse(open(sys.argv[1]).read())" "$workdir/$file" 2>/dev/null; then
                        warn "Syntax error in Python file: $file"
                        issues=$((issues + 1))
                    fi
                fi
                ;;
            *.json)
                if command -v jq >/dev/null 2>&1 && ! jq empty "$workdir/$file" 2>/dev/null; then
                    warn "Invalid JSON: $file"
                    issues=$((issues + 1))
                fi
                ;;
            *.ts|*.js|*.tsx|*.jsx)
                # Check for obvious corruption: API error text leaked into source
                if grep -qE '(CLAUDE_CODE_OAUTH_TOKEN|api key|rate limit|503 Service|DOCTYPE html)' "$workdir/$file" 2>/dev/null; then
                    warn "Claude API error leaked into source file: $file"
                    issues=$((issues + 1))
                fi
                ;;
        esac
    done <<< "$changed_files"

    # Check for obviously corrupt output (API errors dumped as code)
    local total_changed
    total_changed=$(echo "$changed_files" | grep -c '.' 2>/dev/null || true)
    total_changed="${total_changed:-0}"
    if [[ "$total_changed" -eq 0 ]]; then
        warn "Claude iteration produced no file changes"
        issues=$((issues + 1))
    fi

    return "$issues"
}

# ─── Budget Gate (hard stop when exhausted) ───────────────────────────────────
check_budget_gate() {
    [[ ! -x "$SCRIPT_DIR/sw-cost.sh" ]] && return 0
    local remaining
    remaining=$(bash "$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
    [[ -z "$remaining" ]] && return 0
    [[ "$remaining" == "unlimited" ]] && return 0

    # Parse remaining as float, check if <= 0
    if awk -v r="$remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
        error "Budget exhausted (remaining: \$${remaining}) — stopping pipeline"
        emit_event "pipeline.budget_exhausted" "remaining=$remaining"
        return 1
    fi

    # Warn at 10% threshold (remaining < 1.0 when typical job ~$5+)
    if awk -v r="$remaining" 'BEGIN { exit !(r < 1.0) }' 2>/dev/null; then
        warn "Budget low: \$${remaining} remaining"
    fi

    return 0
}

# ─── Git Helpers ──────────────────────────────────────────────────────────────

git_commit_count() {
    git -C "$PROJECT_ROOT" rev-list --count HEAD 2>/dev/null || echo 0
}

git_recent_log() {
    git -C "$PROJECT_ROOT" log --oneline -20 2>/dev/null || echo "(no commits)"
}

git_diff_stat() {
    git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo ""
}

git_auto_commit() {
    local work_dir="${1:-$PROJECT_ROOT}"
    # Only commit if there are changes
    if git -C "$work_dir" diff --quiet && git -C "$work_dir" diff --cached --quiet; then
        # Check for untracked files
        local untracked
        untracked="$(git -C "$work_dir" ls-files --others --exclude-standard | head -1)"
        if [[ -z "$untracked" ]]; then
            return 1  # Nothing to commit
        fi
    fi

    git -C "$work_dir" add -A 2>/dev/null || true

    # Semantic validation before commit — skip commit if validation fails
    if ! validate_claude_output "$work_dir"; then
        warn "Validation failed — skipping commit for this iteration"
        git -C "$work_dir" reset --hard HEAD 2>/dev/null || true
        return 1
    fi

    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}

# ─── Fatal Error Detection ────────────────────────────────────────────────────


# ─── Progress & Circuit Breaker ───────────────────────────────────────────────





# ─── Failure Diagnosis ─────────────────────────────────────────────────────────
# Pattern-based root-cause classification for smarter retries (no Claude needed).
# Returns markdown context to inject into the next iteration's goal.

diagnose_failure() {
    local error_output="$1"
    local changed_files="$2"
    local iteration="$3"

    local diagnosis=""
    local strategy="retry_with_context"  # default

    # Pattern-based classification (fast, no Claude needed)
    if echo "$error_output" | grep -qiE 'import.*not found|cannot find module|no module named'; then
        diagnosis="missing_import"
        strategy="fix_imports"
    elif echo "$error_output" | grep -qiE 'syntax error|unexpected token|parse error'; then
        diagnosis="syntax_error"
        strategy="fix_syntax"
    elif echo "$error_output" | grep -qiE 'type.*not assignable|type error|TypeError'; then
        diagnosis="type_error"
        strategy="fix_types"
    elif echo "$error_output" | grep -qiE 'undefined.*variable|not defined|ReferenceError'; then
        diagnosis="undefined_reference"
        strategy="fix_references"
    elif echo "$error_output" | grep -qiE 'timeout|timed out|ETIMEDOUT'; then
        diagnosis="timeout"
        strategy="optimize_performance"
    elif echo "$error_output" | grep -qiE 'assertion.*fail|expect.*to|AssertionError'; then
        diagnosis="test_assertion"
        strategy="fix_logic"
    elif echo "$error_output" | grep -qiE 'permission denied|EACCES|forbidden'; then
        diagnosis="permission_error"
        strategy="fix_permissions"
    elif echo "$error_output" | grep -qiE 'out of memory|heap|OOM|ENOMEM'; then
        diagnosis="resource_error"
        strategy="reduce_resource_usage"
    else
        diagnosis="unknown"
        strategy="retry_with_context"
    fi

    # Check if we've seen this diagnosis before in this session
    local diagnosis_file="${LOG_DIR}/diagnoses.txt"
    local repeat_count=0
    if [[ -f "$diagnosis_file" ]]; then
        repeat_count=$(grep -c "^${diagnosis}$" "$diagnosis_file" 2>/dev/null || true)
        repeat_count="${repeat_count:-0}"
    fi
    echo "$diagnosis" >> "$diagnosis_file"

    # Escalate strategy if same diagnosis repeats
    if [[ "$repeat_count" -ge 2 ]]; then
        strategy="alternative_approach"
    fi

    # Try memory-based fix lookup
    local known_fix=""
    if type memory_query_fix_for_error &>/dev/null; then
        local fix_json
        fix_json=$(memory_query_fix_for_error "$error_output" 2>/dev/null || true)
        if [[ -n "$fix_json" && "$fix_json" != "null" ]]; then
            known_fix=$(echo "$fix_json" | jq -r '.fix // ""' 2>/dev/null | head -5)
        fi
    fi

    # Build diagnosis context for Claude
    local diagnosis_context="## Failure Diagnosis (Iteration $iteration)
Classification: $diagnosis
Strategy: $strategy
Repeat count: $repeat_count"

    if [[ -n "$known_fix" ]]; then
        diagnosis_context+="
Known fix from memory: $known_fix"
    fi

    # Strategy-specific guidance
    case "$strategy" in
        fix_imports)
            diagnosis_context+="
INSTRUCTION: The error is about missing imports/modules. Check that all imports are correct, packages are installed, and paths are right. Do NOT change the logic - just fix the imports."
            ;;
        fix_syntax)
            diagnosis_context+="
INSTRUCTION: This is a syntax error. Carefully check the exact line mentioned in the error. Look for missing brackets, semicolons, commas, or mismatched quotes."
            ;;
        fix_types)
            diagnosis_context+="
INSTRUCTION: Type mismatch error. Check the types at the error location. Ensure function signatures match their usage."
            ;;
        fix_logic)
            diagnosis_context+="
INSTRUCTION: Test assertion failure. The code logic is wrong, not the syntax. Re-read the test expectations and fix the implementation to match."
            ;;
        alternative_approach)
            diagnosis_context+="
INSTRUCTION: This error has occurred $repeat_count times. The previous approach is not working. Try a FUNDAMENTALLY DIFFERENT approach:
- If you were modifying existing code, try rewriting the function from scratch
- If you were using one library, try a different one
- If you were adding to a file, try creating a new file instead
- Step back and reconsider the requirements"
            ;;
    esac

    echo "$diagnosis_context"
}

# ─── Test Gate ────────────────────────────────────────────────────────────────

run_test_gate() {
    if [[ -z "$TEST_CMD" ]] && [[ ${#ADDITIONAL_TEST_CMDS[@]} -eq 0 ]]; then
        TEST_PASSED=""
        TEST_OUTPUT=""
        return
    fi

    # Determine which test command to use this iteration
    local active_test_cmd="$TEST_CMD"
    local test_mode="full"
    if [[ -n "$FAST_TEST_CMD" ]]; then
        # Use full test every FAST_TEST_INTERVAL iterations, on first iteration, and on final iteration
        if [[ "$ITERATION" -eq 1 ]] || [[ $(( ITERATION % FAST_TEST_INTERVAL )) -eq 0 ]] || [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]]; then
            active_test_cmd="$TEST_CMD"
            test_mode="full"
        else
            active_test_cmd="$FAST_TEST_CMD"
            test_mode="fast"
        fi
    fi

    local all_passed=true
    local test_results="[]"
    local combined_output=""
    local test_timeout="${SW_TEST_TIMEOUT:-900}"

    # Run primary test command
    if [[ -n "$active_test_cmd" ]]; then
        local test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
        TEST_LOG_FILE="$test_log"
        echo -e "  ${DIM}Running ${test_mode} tests...${RESET}"

        local test_wrapper="$active_test_cmd"
        if command -v timeout >/dev/null 2>&1; then
            test_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            test_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
        fi

        local start_ts exit_code=0
        start_ts=$(date +%s)
        bash -c "$test_wrapper" > "$test_log" 2>&1 || exit_code=$?
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$active_test_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        [[ "$exit_code" -ne 0 ]] && all_passed=false
        combined_output+="$(cat "$test_log" 2>/dev/null)"$'\n'
    fi

    # Run additional test commands (discovered or explicit)
    # Mid-build discovery: find test files created since loop start
    local mid_build_cmds=()
    if [[ -n "${LOOP_START_COMMIT:-}" ]] && type detect_created_test_files >/dev/null 2>&1; then
        while IFS= read -r _cmd; do
            [[ -n "$_cmd" ]] && mid_build_cmds+=("$_cmd")
        done < <(detect_created_test_files "$LOOP_START_COMMIT" 2>/dev/null || true)
    fi
    local all_extra=("${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}" "${mid_build_cmds[@]+"${mid_build_cmds[@]}"}")

    for extra_cmd in "${all_extra[@]+"${all_extra[@]}"}"; do
        [[ -z "$extra_cmd" ]] && continue
        local extra_log="${LOG_DIR}/tests-extra-iter-${ITERATION}.log"
        echo -e "  ${DIM}Running additional: ${extra_cmd}${RESET}"

        local extra_wrapper="$extra_cmd"
        if command -v timeout >/dev/null 2>&1; then
            extra_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        elif command -v gtimeout >/dev/null 2>&1; then
            extra_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$extra_cmd")"
        fi

        local start_ts exit_code=0
        start_ts=$(date +%s)
        bash -c "$extra_wrapper" >> "$extra_log" 2>&1 || exit_code=$?
        local duration=$(( $(date +%s) - start_ts ))

        if command -v jq >/dev/null 2>&1; then
            test_results=$(echo "$test_results" | jq --arg cmd "$extra_cmd" \
                --argjson exit "$exit_code" --argjson dur "$duration" \
                '. + [{"command": $cmd, "exit_code": $exit, "duration_s": $dur}]')
        fi

        [[ "$exit_code" -ne 0 ]] && all_passed=false
        combined_output+="$(cat "$extra_log" 2>/dev/null)"$'\n'
    done

    # Write structured test evidence
    if command -v jq >/dev/null 2>&1; then
        echo "$test_results" > "${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    fi

    # Audit: emit test gate event
    if type audit_emit >/dev/null 2>&1; then
        local cmd_count=0
        command -v jq >/dev/null 2>&1 && cmd_count=$(echo "$test_results" | jq 'length' 2>/dev/null || echo 0)
        audit_emit "loop.test_gate" "iteration=$ITERATION" "commands=$cmd_count" \
            "all_passed=$all_passed" "evidence_path=test-evidence-iter-${ITERATION}.json" || true
    fi

    TEST_PASSED=$all_passed
    TEST_OUTPUT="$(echo "$combined_output" | tail -50)"
}

write_error_summary() {
    local error_json="$LOG_DIR/error-summary.json"

    # Write on test failure OR build failure (non-zero exit from Claude iteration)
    local build_log="$LOG_DIR/iteration-${ITERATION}.log"
    if [[ "${TEST_PASSED:-}" != "false" ]]; then
        # Check for build-level failures (Claude iteration exited non-zero or produced errors)
        local build_had_errors=false
        if [[ -f "$build_log" ]]; then
            local build_err_count
            build_err_count=$(tail -30 "$build_log" 2>/dev/null | grep -ciE '(error|fail|exception|panic|FATAL)' || true)
            [[ "${build_err_count:-0}" -gt 0 ]] && build_had_errors=true
        fi
        if [[ "$build_had_errors" != "true" ]]; then
            # Clear previous error summary on success
            rm -f "$error_json" 2>/dev/null || true
            return
        fi
    fi

    # Prefer test log, fall back to build log
    local test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-${ITERATION}.log}"
    local source_log="$test_log"
    if [[ ! -f "$source_log" ]]; then
        source_log="$build_log"
    fi
    [[ ! -f "$source_log" ]] && return

    # Extract error lines (last 30 lines, grep for error patterns)
    local error_lines_raw
    error_lines_raw=$(tail -30 "$source_log" 2>/dev/null | grep -iE '(error|fail|assert|exception|panic|FAIL|TypeError|ReferenceError|SyntaxError)' | head -10 || true)

    local error_count=0
    if [[ -n "$error_lines_raw" ]]; then
        error_count=$(echo "$error_lines_raw" | wc -l | tr -d ' ')
    fi

    local tmp_json="${error_json}.tmp.$$"

    # Build JSON with jq (preferred) or plain-text fallback
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --argjson iteration "${ITERATION:-0}" \
            --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
            --argjson error_count "${error_count:-0}" \
            --arg error_lines "$error_lines_raw" \
            --arg test_cmd "${TEST_CMD:-}" \
            '{
                iteration: $iteration,
                timestamp: $timestamp,
                error_count: $error_count,
                error_lines: ($error_lines | split("\n") | map(select(length > 0))),
                test_cmd: $test_cmd
            }' > "$tmp_json" 2>/dev/null && mv "$tmp_json" "$error_json" || rm -f "$tmp_json" 2>/dev/null
    else
        # Fallback: write plain-text error summary (still machine-parseable)
        cat > "$tmp_json" <<ERRJSON
{"iteration":${ITERATION:-0},"error_count":${error_count:-0},"error_lines":[],"test_cmd":"test"}
ERRJSON
        mv "$tmp_json" "$error_json" 2>/dev/null || rm -f "$tmp_json" 2>/dev/null
    fi
}

# ─── Audit Agent ─────────────────────────────────────────────────────────────

run_audit_agent() {
    if ! $AUDIT_AGENT_ENABLED; then
        return
    fi

    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local audit_log="$LOG_DIR/audit-iter-${ITERATION}.log"

    # Gather context: tail of implementer output + cumulative diff
    local impl_tail
    impl_tail="$(tail -100 "$log_file" 2>/dev/null || echo "(no output)")"

    # Use cumulative diff from loop start so auditor sees ALL work, not just latest commit
    local diff_stat cumulative_note=""
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no changes)")"
        cumulative_note="Note: This diff shows ALL changes since the loop started (iteration 1 through ${ITERATION}), not just the latest commit."
    else
        diff_stat="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null || echo "(no changes)")"
    fi

    # Include verified test status so auditor doesn't have to guess
    local test_context=""
    local evidence_file="${LOG_DIR}/test-evidence-iter-${ITERATION}.json"
    if [[ -f "$evidence_file" ]] && command -v jq >/dev/null 2>&1; then
        local cmd_count total_cmds evidence_detail
        cmd_count=$(jq 'length' "$evidence_file" 2>/dev/null || echo 0)
        total_cmds=$(jq -r '[.[].command] | join(", ")' "$evidence_file" 2>/dev/null || echo "unknown")
        evidence_detail=$(jq -r '.[] | "- \(.command): exit \(.exit_code) (\(.duration_s)s)"' "$evidence_file" 2>/dev/null || echo "")
        test_context="## Verified Test Status (from harness, not from agent)
Test commands run: ${cmd_count} (${total_cmds})
${evidence_detail}
Overall: $(if [[ "${TEST_PASSED:-}" == "true" ]]; then echo "ALL PASSING"; else echo "FAILING"; fi)"
    elif [[ -n "$TEST_CMD" ]]; then
        # Fallback to existing boolean
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            test_context="## Verified Test Status (from harness, not from agent)
Tests: ALL PASSING (command: ${TEST_CMD})"
        else
            test_context="## Verified Test Status (from harness)
Tests: FAILING (command: ${TEST_CMD})
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local audit_prompt
    read -r -d '' audit_prompt <<AUDIT_PROMPT || true
You are an independent code auditor reviewing an autonomous coding agent's CUMULATIVE work.
This is iteration ${ITERATION}. The agent may have done most of the work in earlier iterations.

## Goal the agent was working toward
${GOAL}

## Agent Output This Iteration (last 100 lines)
${impl_tail}

## Cumulative Changes Made (git diff --stat)
${cumulative_note}
${diff_stat}

${test_context}

## Your Task
Critically review the CUMULATIVE work (not just the latest iteration):
1. Has the agent made meaningful progress toward the goal across all iterations?
2. Are there obvious bugs, logic errors, or security issues in the current codebase?
3. Did the agent leave incomplete work (TODOs, placeholder code)?
4. Are there any regressions or broken patterns?
5. Is the code quality acceptable?

IMPORTANT: If the current iteration made small or no code changes, that may be acceptable
if earlier iterations already completed the substantive work. Judge the whole body of work.

If the work is acceptable and moves toward the goal, output exactly: AUDIT_PASS
Otherwise, list the specific issues that need fixing.
AUDIT_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running audit agent..."

    # Select audit model adaptively (haiku if success rate high, else sonnet)
    local audit_model
    audit_model="$(select_audit_model)"
    local audit_flags=()
    audit_flags+=("--model" "$audit_model")
    if $SKIP_PERMISSIONS; then
        audit_flags+=("--dangerously-skip-permissions")
    fi

    # Use structured output for machine-parseable audit results.
    # The dialect key ($schema) is stripped: the claude CLI validates the schema
    # against its own bundled dialects and rejects an unresolvable $schema URI
    # outright, which fails the audit before it ever runs.
    local schema_file="${SCRIPT_DIR}/../schemas/audit-result.json"
    if [[ -f "$schema_file" ]]; then
        local audit_schema
        if command -v jq >/dev/null 2>&1; then
            audit_schema="$(jq -c 'del(.["$schema"])' "$schema_file" 2>/dev/null || true)"
        fi
        [[ -n "${audit_schema:-}" ]] && audit_flags+=("--json-schema" "$audit_schema")
    fi

    local exit_code=0
    claude -p "$audit_prompt" "${audit_flags[@]}" > "$audit_log" 2>&1 || exit_code=$?

    if grep -q "AUDIT_PASS" "$audit_log" 2>/dev/null; then
        AUDIT_RESULT="pass"
        AUDIT_UNAVAILABLE_STREAK=0
        echo -e "  ${GREEN}✓${RESET} Audit: passed"
    elif [[ $exit_code -ne 0 ]]; then
        # The auditor never ran (CLI/flag/auth failure). Its stderr is not a
        # review of the agent's work, so do not feed it back as findings —
        # that would block completion forever on a tooling fault. But fail-open
        # is bounded: a transient failure is waved through, a persistently
        # broken auditor becomes a blocking finding, because "nobody reviewed
        # this" is not the same as "this passed review".
        AUDIT_UNAVAILABLE_STREAK=$(( AUDIT_UNAVAILABLE_STREAK + 1 ))
        emit_event "loop.audit_unavailable" "iteration=$ITERATION" "exit_code=$exit_code" \
            "streak=$AUDIT_UNAVAILABLE_STREAK" "limit=$AUDIT_UNAVAILABLE_LIMIT"
        if [[ $AUDIT_UNAVAILABLE_STREAK -le $AUDIT_UNAVAILABLE_LIMIT ]]; then
            AUDIT_RESULT="pass"
            echo -e "  ${YELLOW}⚠${RESET} Audit: skipped (auditor unavailable, exit ${exit_code}; ${AUDIT_UNAVAILABLE_STREAK}/${AUDIT_UNAVAILABLE_LIMIT})"
        else
            AUDIT_RESULT="Audit agent has been unavailable for ${AUDIT_UNAVAILABLE_STREAK} consecutive iterations (last exit ${exit_code}). The work is unreviewed, not approved. Fix the auditor invocation (see ${audit_log}) before completing."
            echo -e "  ${RED}✗${RESET} Audit: unavailable ${AUDIT_UNAVAILABLE_STREAK}x — treating as blocking"
        fi
    else
        AUDIT_UNAVAILABLE_STREAK=0
        AUDIT_RESULT="$(grep -v '^$' "$audit_log" | tail -20 | head -10 2>/dev/null || echo "Audit returned no output")"
        echo -e "  ${YELLOW}⚠${RESET} Audit: issues found"
    fi
}

# ─── Quality Gates ───────────────────────────────────────────────────────────

run_quality_gates() {
    if ! $QUALITY_GATES_ENABLED; then
        QUALITY_GATE_PASSED=true
        return
    fi

    QUALITY_GATE_PASSED=true
    local gate_failures=()

    echo -e "  ${PURPLE}▸${RESET} Running quality gates..."

    # Gate 1: Tests pass (if TEST_CMD set)
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        gate_failures+=("tests failing")
    fi

    # Gate 2: No uncommitted changes
    if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
       ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null; then
        gate_failures+=("uncommitted changes present")
    fi

    # Gate 3: No TODO/FIXME/HACK/XXX in new source code
    # Exclude .claude/, docs/plans/, and markdown files (which legitimately contain task markers)
    local todo_count
    todo_count="$(git -C "$PROJECT_ROOT" diff HEAD~1 -- ':!.claude/' ':!docs/plans/' ':!*.md' 2>/dev/null \
        | grep -cE '^\+.*(TODO|FIXME|HACK|XXX)' || true)"
    todo_count="${todo_count:-0}"
    if [[ "${todo_count:-0}" -gt 0 ]]; then
        gate_failures+=("${todo_count} TODO/FIXME/HACK/XXX markers in new code")
    fi

    # Gate 4: Definition of Done (if DOD_FILE set)
    if [[ -n "$DOD_FILE" ]]; then
        if ! check_definition_of_done; then
            gate_failures+=("definition of done not satisfied")
        fi
    fi

    if [[ ${#gate_failures[@]} -gt 0 ]]; then
        QUALITY_GATE_PASSED=false
        local failures_str
        failures_str="$(printf ', %s' "${gate_failures[@]}")"
        failures_str="${failures_str:2}"  # trim leading ", "
        echo -e "  ${RED}✗${RESET} Quality gates: FAILED (${failures_str})"
    else
        echo -e "  ${GREEN}✓${RESET} Quality gates: all passed"
    fi
}

check_definition_of_done() {
    if [[ ! -f "$DOD_FILE" ]]; then
        warn "Definition of done file not found: $DOD_FILE"
        return 1
    fi

    local dod_content
    dod_content="$(cat "$DOD_FILE")"

    # Use cumulative diff from loop start (not just HEAD~1) so the evaluator
    # can see ALL work done across every iteration, not just the latest commit.
    local diff_content
    if [[ -n "${LOOP_START_COMMIT:-}" ]]; then
        diff_content="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null || echo "(no diff)")"
        diff_content="${diff_content}

## Detailed Changes (cumulative diff, truncated to 200 lines)
$(git -C "$PROJECT_ROOT" diff "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -200 || echo "(no diff)")"
    else
        diff_content="$(git -C "$PROJECT_ROOT" diff HEAD~1 2>/dev/null || echo "(no diff)")"
    fi

    # Inject verified runtime facts so the evaluator doesn't have to guess
    local runtime_facts=""
    if [[ -n "$TEST_CMD" ]]; then
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            runtime_facts="## Verified Runtime Facts (from the loop harness, not from the agent)
- Tests: ALL PASSING (verified by running '${TEST_CMD}' after this iteration)
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        else
            runtime_facts="## Verified Runtime Facts
- Tests: FAILING (verified by running '${TEST_CMD}')
- Test output (last 10 lines):
$(echo "${TEST_OUTPUT:-}" | tail -10)"
        fi
    fi

    local dod_prompt
    read -r -d '' dod_prompt <<DOD_PROMPT || true
You are evaluating whether a project satisfies a Definition of Done checklist.
You are reviewing the CUMULATIVE work across all iterations, not just the latest commit.

## Definition of Done
${dod_content}

${runtime_facts}

## Cumulative Changes Made (git diff from start of loop to now)
${diff_content}

## Your Task
For each item in the Definition of Done, determine if the project satisfies it.
The runtime facts above are verified by the harness — trust them as ground truth.
If ALL items are satisfied, output exactly: DOD_PASS
Otherwise, list which items are NOT satisfied and why.
DOD_PROMPT

    local dod_log="$LOG_DIR/dod-iter-${ITERATION}.log"
    local dod_model
    dod_model="$(select_audit_model)"
    local dod_flags=()
    dod_flags+=("--model" "$dod_model")
    if $SKIP_PERMISSIONS; then
        dod_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$dod_prompt" "${dod_flags[@]}" > "$dod_log" 2>&1 || true

    if grep -q "DOD_PASS" "$dod_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Definition of Done: satisfied"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Definition of Done: not satisfied"
        return 1
    fi
}

# ─── Guarded Completion ──────────────────────────────────────────────────────

guard_completion() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"

    # Check if LOOP_COMPLETE is in the log
    if ! grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null; then
        return 1  # No completion claim
    fi

    echo -e "  ${CYAN}▸${RESET} LOOP_COMPLETE detected — validating..."

    local rejection_reasons=()

    # Check quality gates
    if ! $QUALITY_GATE_PASSED; then
        rejection_reasons+=("quality gates failed")
    fi

    # Check audit agent
    if $AUDIT_AGENT_ENABLED && [[ "$AUDIT_RESULT" != "pass" ]]; then
        rejection_reasons+=("audit agent found issues")
    fi

    # Check tests
    if [[ -n "$TEST_CMD" ]] && [[ "$TEST_PASSED" == "false" ]]; then
        rejection_reasons+=("tests failing")
    fi

    # Holistic final gate: when all other gates pass, run a project-level assessment
    # that evaluates the entire codebase against the goal (not just the latest diff)
    if [[ ${#rejection_reasons[@]} -eq 0 ]]; then
        if ! run_holistic_gate; then
            rejection_reasons+=("holistic project assessment found gaps")
        fi
    fi

    if [[ ${#rejection_reasons[@]} -gt 0 ]]; then
        local reasons_str
        reasons_str="$(printf ', %s' "${rejection_reasons[@]}")"
        reasons_str="${reasons_str:2}"
        echo -e "  ${RED}✗${RESET} Completion REJECTED: ${reasons_str}"
        COMPLETION_REJECTED=true
        return 1
    fi

    echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE accepted — all gates passed!${RESET}"
    return 0
}

# Holistic gate: evaluates the full project against the original goal.
# Only runs when all other gates pass (final checkpoint before acceptance).
run_holistic_gate() {
    # Skip if no starting commit (can't compute cumulative diff)
    [[ -z "${LOOP_START_COMMIT:-}" ]] && return 0

    local holistic_log="$LOG_DIR/holistic-iter-${ITERATION}.log"

    # Build a project summary: file tree, test count, cumulative diff stats
    local file_count
    file_count=$(git -C "$PROJECT_ROOT" ls-files | wc -l | tr -d ' ')
    local cumulative_stat
    cumulative_stat="$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | tail -1 || echo "(no changes)")"
    local test_summary=""
    if [[ -n "${TEST_OUTPUT:-}" ]]; then
        test_summary="$(echo "$TEST_OUTPUT" | tail -5)"
    fi

    local holistic_prompt
    read -r -d '' holistic_prompt <<HOLISTIC_PROMPT || true
You are a final quality gate evaluating whether an autonomous coding agent has FULLY achieved its goal.

## Original Goal
${GOAL}

## Project Stats
- Files in repo: ${file_count}
- Iterations completed: ${ITERATION}
- Cumulative changes: ${cumulative_stat}
- Tests: ${TEST_PASSED:-unknown} (command: ${TEST_CMD:-none})
${test_summary:+- Test output: ${test_summary}}

## Cumulative Git Changes (diff --stat from start)
$(git -C "$PROJECT_ROOT" diff --stat "${LOOP_START_COMMIT}..HEAD" 2>/dev/null | head -40 || echo "(none)")

## Your Task
Based on the goal and the cumulative work done:
1. Has the goal been FULLY achieved (not partially)?
2. Is there any critical gap that would make this unacceptable for production?

If the goal is fully achieved, output exactly: HOLISTIC_PASS
Otherwise, list the specific gaps remaining.
HOLISTIC_PROMPT

    echo -e "  ${PURPLE}▸${RESET} Running holistic project assessment..."

    local hol_model
    hol_model="$(select_audit_model)"
    local hol_flags=("--model" "$hol_model")
    if $SKIP_PERMISSIONS; then
        hol_flags+=("--dangerously-skip-permissions")
    fi

    claude -p "$holistic_prompt" "${hol_flags[@]}" > "$holistic_log" 2>&1 || true

    if grep -q "HOLISTIC_PASS" "$holistic_log" 2>/dev/null; then
        echo -e "  ${GREEN}✓${RESET} Holistic assessment: passed"
        return 0
    else
        echo -e "  ${YELLOW}⚠${RESET} Holistic assessment: gaps found"
        return 1
    fi
}

# ─── Context Window Management ───────────────────────────────────────────────

# ─── Prompt Composition ──────────────────────────────────────────────────────
# NOTE: compose_prompt() is now in lib/loop-iteration.sh (extracted upstream)

# ─── Alternative Strategy Exploration ─────────────────────────────────────────
# When stuckness is detected, generate a context-aware alternative strategy.
# Uses pattern matching on error type + iteration count to suggest different approaches.


# ─── Stuckness Detection ─────────────────────────────────────────────────────
# Multi-signal detection: text overlap, git diff hash, error repetition, exit code pattern, iteration budget.
# Returns 0 when stuck, 1 when not. Outputs stuckness section and sets STUCKNESS_HINT when stuck.
# When stuck: increments STUCKNESS_COUNT, emits event; if STUCKNESS_COUNT >= 3, caller triggers session restart.
STUCKNESS_COUNT=0
STUCKNESS_TRACKING_FILE=""



compose_audit_section() {
    if ! $AUDIT_ENABLED; then
        return
    fi

    # Try to inject audit items from past review feedback in memory
    local memory_audit_items=""
    if [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        local mem_dir_path
        mem_dir_path="$HOME/.shipwright/memory"
        # Look for review feedback in any repo memory
        local repo_hash_val
        repo_hash_val=$(git config --get remote.origin.url 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-12 || echo "")
        if [[ -n "$repo_hash_val" && -f "$mem_dir_path/$repo_hash_val/failures.json" ]]; then
            memory_audit_items=$(jq -r '.failures[] | select(.stage == "review" and .pattern != "") |
                "- Check for: \(.pattern[:100])"' \
                "$mem_dir_path/$repo_hash_val/failures.json" 2>/dev/null | head -5 || true)
        fi
    fi

    echo "## Self-Audit Checklist"
    echo "Before declaring LOOP_COMPLETE, critically evaluate your own work:"
    echo "1. Does the implementation FULLY satisfy the goal, not just partially?"
    echo "2. Are there any edge cases you haven't handled?"
    echo "3. Did you leave any TODO, FIXME, HACK, or XXX comments in new code?"
    echo "4. Are all new functions/modules tested (if a test command exists)?"
    echo "5. Would a code reviewer approve this, or would they request changes?"
    echo "6. Is the code clean, well-structured, and following project conventions?"
    if [[ -n "$memory_audit_items" ]]; then
        echo ""
        echo "Common review findings from this repo's history:"
        echo "$memory_audit_items"
    fi
    echo ""
    echo "If ANY answer is \"no\", do NOT output LOOP_COMPLETE. Instead, fix the issues first."
}

compose_audit_feedback_section() {
    if [[ -z "$AUDIT_RESULT" ]] || [[ "$AUDIT_RESULT" == "pass" ]]; then
        return
    fi
    cat <<AUDIT_FEEDBACK
## Audit Feedback (Previous Iteration)
An independent audit of your last iteration found these issues:
${AUDIT_RESULT}

Address ALL audit findings before proceeding with new work.
AUDIT_FEEDBACK
}

compose_rejection_notice_section() {
    if ! $COMPLETION_REJECTED; then
        return
    fi
    COMPLETION_REJECTED=false
    cat <<'REJECTION'
## ⚠ Completion Rejected
Your previous LOOP_COMPLETE was REJECTED because quality gates did not pass.
Review the audit feedback and test results above, fix the issues, then try again.
Do NOT output LOOP_COMPLETE until all quality checks pass.
REJECTION
}

compose_worker_prompt() {
    local agent_num="$1"
    local total_agents="$2"

    local base_prompt
    base_prompt="$(compose_prompt)"

    # Role-specific instructions
    local role_section=""
    if [[ -n "$AGENT_ROLES" ]] && [[ "${agent_num:-0}" -ge 1 ]]; then
        # Split comma-separated roles and get role for this agent
        local role=""
        local IFS_BAK="$IFS"
        IFS=',' read -ra _roles <<< "$AGENT_ROLES"
        IFS="$IFS_BAK"
        if [[ "$agent_num" -le "${#_roles[@]}" ]]; then
            role="${_roles[$((agent_num - 1))]}"
            # Trim whitespace and skip empty roles (handles trailing comma)
            role="$(echo "$role" | tr -d ' ')"
        fi

        if [[ -n "$role" ]]; then
            local role_desc=""
            # Try to pull description from recruit's roles DB first
            local recruit_roles_db="${HOME}/.shipwright/recruitment/roles.json"
            if [[ -f "$recruit_roles_db" ]] && command -v jq >/dev/null 2>&1; then
                local recruit_desc
                recruit_desc=$(jq -r --arg r "$role" '.[$r].description // ""' "$recruit_roles_db" 2>/dev/null) || true
                if [[ -n "$recruit_desc" && "$recruit_desc" != "null" ]]; then
                    role_desc="$recruit_desc"
                fi
            fi
            # Fallback to built-in role descriptions
            if [[ -z "$role_desc" ]]; then
                case "$role" in
                    builder)   role_desc="Focus on implementation — writing code, fixing bugs, building features. You are the primary builder." ;;
                    reviewer)  role_desc="Focus on code review — look for bugs, security issues, edge cases in recent commits. Make fixes via commits." ;;
                    tester)    role_desc="Focus on test coverage — write new tests, fix failing tests, improve assertions and edge case coverage." ;;
                    optimizer) role_desc="Focus on performance — profile hot paths, reduce complexity, optimize algorithms and data structures." ;;
                    docs|docs-writer) role_desc="Focus on documentation — update README, add docstrings, write usage guides for new features." ;;
                    security|security-auditor) role_desc="Focus on security — audit for vulnerabilities, fix injection risks, validate inputs, check auth boundaries." ;;
                    *)         role_desc="Focus on: ${role}. Apply your expertise in this area to advance the goal." ;;
                esac
            fi
            role_section="## Your Role: ${role}
${role_desc}
Prioritize work in your area of expertise. Coordinate with other agents via git log."
        fi
    fi

    cat <<PROMPT
${base_prompt}

## Agent Identity
You are Agent ${agent_num} of ${total_agents}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

${role_section}
PROMPT
}

# ─── Claude Execution ────────────────────────────────────────────────────────



# ─── Iteration Summary Extraction ────────────────────────────────────────────


# ─── Display Helpers ─────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright${RESET} ${DIM}v${VERSION}${RESET} — ${BOLD}Continuous Loop${RESET}"
    echo -e "${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}  $GOAL"
    local extend_info=""
    if $AUTO_EXTEND; then
        extend_info=" ${DIM}(auto-extend: +${EXTENSION_SIZE} x${MAX_EXTENSIONS})${RESET}"
    fi
    echo -e "  ${BOLD}Model:${RESET} $MODEL ${DIM}|${RESET} ${BOLD}Max:${RESET} $MAX_ITERATIONS iterations${extend_info} ${DIM}|${RESET} ${BOLD}Test:${RESET} ${TEST_CMD:-"(none)"}"
    if [[ "$AGENTS" -gt 1 ]]; then
        echo -e "  ${BOLD}Agents:${RESET} $AGENTS ${DIM}(parallel worktree mode)${RESET}"
    fi
    if $SKIP_PERMISSIONS; then
        echo -e "  ${YELLOW}${BOLD}⚠${RESET}  ${YELLOW}--dangerously-skip-permissions enabled${RESET}"
    fi
    if $AUDIT_ENABLED || $AUDIT_AGENT_ENABLED || $QUALITY_GATES_ENABLED; then
        echo -e "  ${BOLD}Audit:${RESET} ${AUDIT_ENABLED:+self-audit }${AUDIT_AGENT_ENABLED:+audit-agent }${QUALITY_GATES_ENABLED:+quality-gates}${DIM}${DOD_FILE:+ | DoD: $DOD_FILE}${RESET}"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

show_summary() {
    local end_epoch
    end_epoch="$(now_epoch)"
    local duration=$(( end_epoch - START_EPOCH ))

    local status_display
    case "$STATUS" in
        complete)         status_display="${GREEN}✓ Complete (LOOP_COMPLETE detected)${RESET}" ;;
        circuit_breaker)  status_display="${RED}✗ Circuit breaker tripped${RESET}" ;;
        max_iterations)   status_display="${YELLOW}⚠ Max iterations reached${RESET}" ;;
        budget_exhausted) status_display="${RED}✗ Budget exhausted${RESET}" ;;
        interrupted)      status_display="${YELLOW}⚠ Interrupted by user${RESET}" ;;
        error)            status_display="${RED}✗ Error${RESET}" ;;
        *)                status_display="${DIM}$STATUS${RESET}" ;;
    esac

    local test_display
    if [[ -z "$TEST_CMD" ]]; then
        test_display="${DIM}No tests configured${RESET}"
    elif [[ "$TEST_PASSED" == "true" ]]; then
        test_display="${GREEN}All passing${RESET}"
    elif [[ "$TEST_PASSED" == "false" ]]; then
        test_display="${RED}Failing${RESET}"
    else
        test_display="${DIM}Not run${RESET}"
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    local status_upper
    status_upper="$(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
    echo -e "  ${BOLD}LOOP ${status_upper}${RESET}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${BOLD}Goal:${RESET}        $GOAL"
    echo -e "  ${BOLD}Status:${RESET}      $status_display"
    local ext_suffix=""
    [[ "$EXTENSION_COUNT" -gt 0 ]] && ext_suffix=" ${DIM}(${EXTENSION_COUNT} extensions)${RESET}"
    echo -e "  ${BOLD}Iterations:${RESET}  $ITERATION/$MAX_ITERATIONS${ext_suffix}"
    echo -e "  ${BOLD}Duration:${RESET}    $(format_duration "$duration")"
    echo -e "  ${BOLD}Commits:${RESET}     $TOTAL_COMMITS"
    echo -e "  ${BOLD}Tests:${RESET}       $test_display"
    if [[ "$LOOP_INPUT_TOKENS" -gt 0 || "$LOOP_OUTPUT_TOKENS" -gt 0 ]]; then
        echo -e "  ${BOLD}Tokens:${RESET}      in=${LOOP_INPUT_TOKENS} out=${LOOP_OUTPUT_TOKENS}"
    fi
    echo ""
    echo -e "  ${DIM}State: $STATE_FILE${RESET}"
    echo -e "  ${DIM}Logs:  $LOG_DIR/${RESET}"
    echo ""

    # Write token totals for pipeline cost tracking
    write_loop_tokens
}

# ─── Signal Handling ──────────────────────────────────────────────────────────

CHILD_PID=""

cleanup() {
    echo ""
    warn "Loop interrupted at iteration $ITERATION"

    # Kill any running Claude process
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi

    # If multi-agent, kill worker panes
    if [[ "$AGENTS" -gt 1 ]]; then
        cleanup_multi_agent
    fi

    STATUS="interrupted"
    write_state

    # Save checkpoint on interruption
    "$SCRIPT_DIR/sw-checkpoint.sh" save \
        --stage "build" \
        --iteration "$ITERATION" \
        --git-sha "$(git rev-parse HEAD 2>/dev/null || echo unknown)" 2>/dev/null || true

    # Save Claude context for meaningful resume (goal, findings, test output)
    export SW_LOOP_GOAL="$GOAL"
    export SW_LOOP_ITERATION="$ITERATION"
    export SW_LOOP_STATUS="$STATUS"
    export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
    export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
    # shellcheck disable=SC2155
    export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
    "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

    # Clear heartbeat
    "$SCRIPT_DIR/sw-heartbeat.sh" clear "${PIPELINE_JOB_ID:-loop-$$}" 2>/dev/null || true

    show_summary
    exit 130
}

trap cleanup SIGINT SIGTERM

# ─── Multi-Agent: Worktree Setup ─────────────────────────────────────────────

setup_worktrees() {
    local branch_base="loop"
    mkdir -p "$WORKTREE_DIR"

    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        local branch_name="${branch_base}/agent-${i}"

        if [[ -d "$wt_path" ]]; then
            info "Worktree agent-${i} already exists"
            continue
        fi

        # Create branch if it doesn't exist
        if ! git -C "$PROJECT_ROOT" rev-parse --verify "$branch_name" >/dev/null 2>&1; then
            git -C "$PROJECT_ROOT" branch "$branch_name" HEAD 2>/dev/null || true
        fi

        git -C "$PROJECT_ROOT" worktree add "$wt_path" "$branch_name" 2>/dev/null || {
            error "Failed to create worktree for agent-${i}"
            return 1
        }

        success "Worktree: agent-${i} → $wt_path"
    done
}

cleanup_worktrees() {
    for i in $(seq 1 "$AGENTS"); do
        local wt_path="$WORKTREE_DIR/agent-${i}"
        if [[ -d "$wt_path" ]]; then
            git -C "$PROJECT_ROOT" worktree remove --force "$wt_path" 2>/dev/null || true
        fi
    done
    rmdir "$WORKTREE_DIR" 2>/dev/null || true
}

# ─── Multi-Agent: Worker Loop Script ─────────────────────────────────────────

generate_worker_script() {
    local agent_num="$1"
    local total_agents="$2"
    local wt_path="$WORKTREE_DIR/agent-${agent_num}"
    local worker_script="$LOG_DIR/worker-${agent_num}.sh"

    local claude_flags
    claude_flags="$(build_claude_flags)"

    cat > "$worker_script" <<'WORKEREOF'
#!/usr/bin/env bash
set -euo pipefail

AGENT_NUM="__AGENT_NUM__"
TOTAL_AGENTS="__TOTAL_AGENTS__"
WORK_DIR="__WORK_DIR__"
LOG_DIR="__LOG_DIR__"
MAX_ITERATIONS="__MAX_ITERATIONS__"
GOAL="__GOAL__"
TEST_CMD="__TEST_CMD__"
CLAUDE_FLAGS="__CLAUDE_FLAGS__"

CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

cd "$WORK_DIR" || { echo "ERROR: Cannot cd to WORK_DIR: $WORK_DIR" >&2; exit 1; }
ITERATION=0
CONSECUTIVE_FAILURES=0

# Source auto-recovery for circuit breaker recovery
# shellcheck source=lib/auto-recovery.sh
[[ -f "__SCRIPT_DIR__/lib/auto-recovery.sh" ]] && source "__SCRIPT_DIR__/lib/auto-recovery.sh" 2>/dev/null || true

echo -e "${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM}/${TOTAL_AGENTS} starting in ${WORK_DIR}"

while [[ "$ITERATION" -lt "$MAX_ITERATIONS" ]]; do
    # Budget gate: stop if daily budget exhausted
    if [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
        budget_remaining=$("$SCRIPT_DIR/sw-cost.sh" remaining-budget 2>/dev/null || echo "")
        if [[ -n "$budget_remaining" && "$budget_remaining" != "unlimited" ]]; then
            if awk -v r="$budget_remaining" 'BEGIN { exit !(r <= 0) }' 2>/dev/null; then
                echo -e "  ${RED}✗${RESET} Budget exhausted (\$${budget_remaining}) — stopping agent ${AGENT_NUM}"
                break
            fi
        fi
    fi

    ITERATION=$(( ITERATION + 1 ))
    echo -e "\n${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM} — Iteration ${ITERATION}/${MAX_ITERATIONS}"

    # Pull latest from other agents
    git fetch origin main 2>/dev/null && git merge origin/main --no-edit 2>/dev/null || true

    # Build prompt
    GIT_LOG="$(git log --oneline -20 2>/dev/null || echo '(no commits)')"
    TEST_SECTION="No test results yet."
    if [[ -n "$TEST_CMD" ]]; then
        TEST_SECTION="Test command: $TEST_CMD"
    fi

    PROMPT="$(cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Recent Git Activity
${GIT_LOG}

## Test Results
${TEST_SECTION}

## Agent Identity
You are Agent ${AGENT_NUM} of ${TOTAL_AGENTS}. Other agents are working in parallel.
Check git log to see what they've done — avoid duplicating their work.
Focus on areas they haven't touched yet.

## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Commit your work with a descriptive message
5. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
)"

    # Run Claude (output is JSON due to --output-format json in CLAUDE_FLAGS)
    local JSON_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.json"
    local ERR_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.stderr"
    LOG_FILE="$LOG_DIR/agent-${AGENT_NUM}-iter-${ITERATION}.log"
    # shellcheck disable=SC2086
    claude -p "$PROMPT" $CLAUDE_FLAGS > "$JSON_FILE" 2>"$ERR_FILE" || true

    # Extract text result from JSON into .log for backwards compat
    _extract_text_from_json "$JSON_FILE" "$LOG_FILE" "$ERR_FILE"

    echo -e "  ${GREEN}✓${RESET} Claude session completed"

    # Check completion
    if grep -q "LOOP_COMPLETE" "$LOG_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}${BOLD}✓ LOOP_COMPLETE detected!${RESET}"
        # Signal completion
        touch "$LOG_DIR/.agent-${AGENT_NUM}-complete"
        break
    fi

    # Auto-commit — stage only source files, exclude build artifacts
    git add -A 2>/dev/null || true
    git reset -- .claude/loop-logs/ .claude/loop-state.md .claude/intelligence-cache.json \
        .claude/platform-hygiene.json .claude/pipeline-artifacts/ .claude/code-review.json \
        .claude/hygiene-report.json .claude/pr-draft.md 2>/dev/null || true
    if git commit -m "agent-${AGENT_NUM}: iteration ${ITERATION}" --no-verify 2>/dev/null; then
        if ! git push origin "loop/agent-${AGENT_NUM}" 2>/dev/null; then
            echo -e "  ${YELLOW}⚠${RESET} git push failed for loop/agent-${AGENT_NUM} — remote may be out of sync"
            type emit_event >/dev/null 2>&1 && emit_event "loop.push_failed" "branch=loop/agent-${AGENT_NUM}"
        else
            echo -e "  ${GREEN}✓${RESET} Committed and pushed"
        fi
    fi

    # Circuit breaker: check for progress
    CHANGES="$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo '')"
    INSERTIONS="$(echo "$CHANGES" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${INSERTIONS:-0}" -lt 5 ]]; then
        CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
        echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/3)"
    else
        CONSECUTIVE_FAILURES=0
    fi

    if [[ "$CONSECUTIVE_FAILURES" -ge 3 ]]; then
        # Attempt auto-recovery before tripping circuit breaker
        if type recovery_before_circuit_breaker >/dev/null 2>&1; then
            if recovery_before_circuit_breaker "" "$WORK_DIR" "$TEST_CMD"; then
                CONSECUTIVE_FAILURES=0
                echo -e "  ${GREEN}✓${RESET} Auto-recovery succeeded — resetting circuit breaker"
                continue
            fi
        fi
        echo -e "  ${RED}✗${RESET} Circuit breaker — stopping agent ${AGENT_NUM}"
        break
    fi

    sleep __SLEEP_BETWEEN_ITERATIONS__
done

echo -e "\n${DIM}Agent ${AGENT_NUM} finished after ${ITERATION} iterations${RESET}"
WORKEREOF

    # Replace placeholders — use awk for all values to avoid sed injection
    # (sed breaks on & | \ in paths and test commands)
    sed_i "s|__AGENT_NUM__|${agent_num}|g" "$worker_script"
    sed_i "s|__TOTAL_AGENTS__|${total_agents}|g" "$worker_script"
    sed_i "s|__MAX_ITERATIONS__|${MAX_ITERATIONS}|g" "$worker_script"
    sed_i "s|__SLEEP_BETWEEN_ITERATIONS__|$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)|g" "$worker_script"
    # Paths and commands may contain sed-special chars — use awk
    awk -v val="$wt_path" '{gsub(/__WORK_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$LOG_DIR" '{gsub(/__LOG_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$SCRIPT_DIR" '{gsub(/__SCRIPT_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$TEST_CMD" '{gsub(/__TEST_CMD__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$claude_flags" '{gsub(/__CLAUDE_FLAGS__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$GOAL" '{gsub(/__GOAL__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    chmod +x "$worker_script"
    echo "$worker_script"
}

# ─── Multi-Agent: Launch ─────────────────────────────────────────────────────

MULTI_WINDOW_NAME=""

launch_multi_agent() {
    info "Setting up multi-agent mode ($AGENTS agents)..."

    # Setup worktrees
    setup_worktrees || { error "Failed to setup worktrees"; exit 1; }

    # Create tmux window for workers
    MULTI_WINDOW_NAME="sw-loop-$(date +%s)"
    tmux new-window -n "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"

    # Capture the first pane's ID (stable regardless of pane-base-index)
    local monitor_pane_id
    monitor_pane_id="$(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null | head -1)"

    # First pane becomes monitor
    tmux send-keys -t "$monitor_pane_id" "printf '\\033]2;loop-monitor\\033\\\\'" Enter
    sleep 0.2
    tmux send-keys -t "$monitor_pane_id" "clear && echo 'Loop Monitor — watching agent logs...'" Enter

    # Create worker panes
    for i in $(seq 1 "$AGENTS"); do
        local worker_script
        worker_script="$(generate_worker_script "$i" "$AGENTS")"

        local worker_pane_id
        worker_pane_id="$(tmux split-window -t "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT" -P -F '#{pane_id}')"
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "printf '\\033]2;agent-${i}\\033\\\\'" Enter
        sleep 0.1
        tmux send-keys -t "$worker_pane_id" "bash '$worker_script'" Enter
    done

    # Layout: monitor pane on top (35%), worker agents tile below
    tmux select-layout -t "$MULTI_WINDOW_NAME" main-vertical 2>/dev/null || true
    tmux resize-pane -t "$monitor_pane_id" -y 35% 2>/dev/null || true

    # In the monitor pane, tail all agent logs
    tmux select-pane -t "$monitor_pane_id"
    sleep 0.5
    tmux send-keys -t "$monitor_pane_id" "clear && tail -f $LOG_DIR/agent-*-iter-*.log 2>/dev/null || echo 'Waiting for agent logs...'" Enter

    success "Launched $AGENTS worker agents in window: $MULTI_WINDOW_NAME"
    echo ""

    # Wait for completion
    info "Monitoring agents... (Ctrl-C to stop all)"
    wait_for_multi_completion
}

wait_for_multi_completion() {
    while true; do
        # Check if any agent signaled completion
        for i in $(seq 1 "$AGENTS"); do
            if [[ -f "$LOG_DIR/.agent-${i}-complete" ]]; then
                success "Agent $i signaled LOOP_COMPLETE!"
                STATUS="complete"
                write_state
                return 0
            fi
        done

        # Check if all worker panes are still running
        local running=0
        for i in $(seq 1 "$AGENTS"); do
            # Check if the worker log is still being written to
            local latest_log
            latest_log="$(ls -t "$LOG_DIR"/agent-"${i}"-iter-*.log 2>/dev/null | head -1)"
            if [[ -n "$latest_log" ]]; then
                local age
                age=$(( $(now_epoch) - $(file_mtime "$latest_log") ))
                if [[ $age -lt 300 ]]; then  # Active within 5 minutes
                    running=$(( running + 1 ))
                fi
            fi
        done

        if [[ $running -eq 0 ]]; then
            # Check if we have any logs at all (might still be starting)
            local total_logs
            total_logs="$(ls "$LOG_DIR"/agent-*-iter-*.log 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "${total_logs:-0}" -gt 0 ]]; then
                warn "All agents appear to have stopped."
                STATUS="complete"
                write_state
                return 0
            fi
        fi

        sleep "$(_config_get_int "loop.multi_agent_sleep" 5 2>/dev/null || echo 5)"
    done
}

cleanup_multi_agent() {
    if [[ -n "$MULTI_WINDOW_NAME" ]]; then
        # Send Ctrl-C to all panes using stable pane IDs (not indices)
        # Pane IDs (%0, %1, ...) are unaffected by pane-base-index setting
        local pane_id
        while IFS= read -r pane_id; do
            [[ -z "$pane_id" ]] && continue
            tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
        done < <(tmux list-panes -t "$MULTI_WINDOW_NAME" -F '#{pane_id}' 2>/dev/null || true)
        sleep 1
        tmux kill-window -t "$MULTI_WINDOW_NAME" 2>/dev/null || true
    fi

    # Clean up completion markers
    rm -f "$LOG_DIR"/.agent-*-complete 2>/dev/null || true
}

# ─── Main: Single-Agent Loop ─────────────────────────────────────────────────

run_single_agent_loop() {
    # Save original environment variables before loop starts
    local SAVED_CLAUDE_MODEL="${CLAUDE_MODEL:-}"
    local SAVED_ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

    # One session ID per invocation of this function, so the iterations inside
    # it continue a single conversation instead of cold-starting each time.
    #
    # run_loop_with_restarts re-enters this function for every restart, so a
    # deliberate restart naturally gets a NEW id. That is required, not
    # incidental: context-exhaustion recovery is *supposed* to drop the old
    # context and re-orient from progress.md, and reusing the id would defeat
    # the very thing the restart exists to do.
    if [[ "${SESSION_CONTINUITY:-0}" == "1" ]]; then
        LOOP_SESSION_ID=$(new_uuid)
        info "Session continuity enabled (session ${LOOP_SESSION_ID})"
    else
        LOOP_SESSION_ID=""
    fi

    if [[ "$SESSION_RESTART" == "true" ]]; then
        # Restart: state already reset by run_loop_with_restarts, skip init
        # Restore environment variables for clean iteration state
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        # Reset context exhaustion counter for this session (it tracks restarts WITHIN a single session)
        CONTEXT_RESTART_COUNT=0
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — fresh context, reading progress"
    elif $RESUME; then
        resume_state
    else
        initialize_state
    fi

    # Ensure LOOP_START_COMMIT is set (may not be on resume/restart)
    if [[ -z "${LOOP_START_COMMIT:-}" ]]; then
        LOOP_START_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse HEAD 2>/dev/null || echo "")"
    fi

    # Apply adaptive budget/model before showing banner
    apply_adaptive_budget
    MODEL="$(select_adaptive_model "build" "$MODEL")"

    # Track applied memory fix patterns for outcome recording
    _applied_fix_pattern=""
    STUCKNESS_COUNT=0
    STUCKNESS_TRACKING_FILE="$LOG_DIR/stuckness-tracking.txt"
    : > "$STUCKNESS_TRACKING_FILE" 2>/dev/null || true
    : > "${LOG_DIR}/strategy-attempts.txt" 2>/dev/null || true

    show_banner

    while true; do
        # Reset environment variables at start of each iteration
        # Prevents previous iterations from affecting model selection or API keys
        [[ -n "$SAVED_CLAUDE_MODEL" ]] && export CLAUDE_MODEL="$SAVED_CLAUDE_MODEL"
        [[ -n "$SAVED_ANTHROPIC_API_KEY" ]] && export ANTHROPIC_API_KEY="$SAVED_ANTHROPIC_API_KEY"

        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        check_max_iterations || break
        check_budget_gate || {
            STATUS="budget_exhausted"
            write_state
            write_progress
            error "Budget exhausted — stopping pipeline"
            show_summary
            return 1
        }
        ITERATION=$(( ITERATION + 1 ))

        # Emit iteration start event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_start" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}"
        fi

        # Root-cause diagnosis and memory-based fix on retry after test failure
        if [[ "${TEST_PASSED:-}" == "false" ]]; then
            # Source memory module for diagnosis and fix lookup
            [[ -f "$SCRIPT_DIR/sw-memory.sh" ]] && source "$SCRIPT_DIR/sw-memory.sh" 2>/dev/null || true

            # Capture failure for memory (enables memory_analyze_failure and future fix lookup)
            if type memory_capture_failure &>/dev/null && [[ -n "${TEST_OUTPUT:-}" ]]; then
                memory_capture_failure "test" "$TEST_OUTPUT" 2>/dev/null || true
            fi

            # Pattern-based diagnosis (no Claude needed) — inject into goal for smarter retry
            local _changed_files=""
            _changed_files=$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')
            local _diagnosis
            _diagnosis=$(diagnose_failure "${TEST_OUTPUT:-}" "$_changed_files" "$ITERATION" 2>/dev/null || true)

            if [[ -n "$_diagnosis" ]]; then
                GOAL="${GOAL}

${_diagnosis}"
                info "Failure diagnosis injected (classification from error pattern)"
            fi

            # Memory-based fix suggestion (from past successful fixes)
            local _last_error=""
            local _prev_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
            if [[ -f "$_prev_log" ]]; then
                _last_error=$(tail -20 "$_prev_log" 2>/dev/null | grep -iE '(error|fail|exception)' | head -1 || true)
            fi
            [[ -z "$_last_error" ]] && _last_error=$(echo "${TEST_OUTPUT:-}" | head -3 | tr '\n' ' ')
            local _fix_suggestion=""
            if type memory_closed_loop_inject >/dev/null 2>&1 && [[ -n "${_last_error:-}" ]]; then
                _fix_suggestion=$(memory_closed_loop_inject "$_last_error" 2>/dev/null) || true
            fi
            if [[ -n "${_fix_suggestion:-}" ]]; then
                _applied_fix_pattern="${_last_error}"
                GOAL="KNOWN FIX (from past success): ${_fix_suggestion}

${GOAL}"
                info "Memory fix injected: ${_fix_suggestion:0:80}"
                # Track memory injection for effectiveness measurement
                if type memeff_on_injection >/dev/null 2>&1; then
                    memeff_on_injection "closed_loop_fix" "${PIPELINE_JOB_ID:-$$}" "build" 2>/dev/null || true
                fi
            fi

            # Analyze failure via Claude (background, non-blocking) for richer root_cause/fix in memory
            if type memory_analyze_failure &>/dev/null && [[ "${INTELLIGENCE_ENABLED:-auto}" != "false" ]]; then
                local _test_log="${TEST_LOG_FILE:-$LOG_DIR/tests-iter-$(( ITERATION - 1 )).log}"
                if [[ -f "$_test_log" ]]; then
                    memory_analyze_failure "$_test_log" "test" 2>/dev/null &
                fi
            fi
        fi

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"

        # Record iteration data for stuckness detection (diff hash, error hash, exit code)
        record_iteration_stuckness_data "$exit_code"

        # Dark factory: score this iteration with process reward model
        if type process_reward_score_iteration >/dev/null 2>&1; then
            process_reward_score_iteration "$PROJECT_ROOT" "${TEST_OUTPUT:-}" "$ITERATION" 2>/dev/null || true
        fi

        # Detect fatal CLI errors (API key, auth, network) — abort immediately
        if check_fatal_error "$log_file" "$exit_code"; then
            STATUS="error"
            write_state
            write_progress
            error "Fatal CLI error detected — aborting loop (see iteration log)"
            show_summary
            return 1
        fi

        # Detect context exhaustion and trigger intelligent restart
        local log_content=""
        [[ -f "$log_file" ]] && log_content=$(cat "$log_file" 2>/dev/null || true)
        local stderr_file="${LOG_DIR}/iteration-${ITERATION}.stderr"
        local stderr_content=""
        [[ -f "$stderr_file" ]] && stderr_content=$(cat "$stderr_file" 2>/dev/null || true)

        if echo "${log_content}${stderr_content}" | grep -qiE "$CONTEXT_EXHAUSTION_PATTERNS" 2>/dev/null; then
            if [[ "${CONTEXT_RESTART_COUNT:-0}" -lt "${CONTEXT_RESTART_LIMIT:-2}" ]]; then
                CONTEXT_RESTART_COUNT=$(( CONTEXT_RESTART_COUNT + 1 ))
                STATUS="context_exhaustion_restart"
                write_state
                write_progress
                warn "Context exhaustion detected (iteration $ITERATION) — triggering intelligent restart ($CONTEXT_RESTART_COUNT/$CONTEXT_RESTART_LIMIT)"
                if type emit_event >/dev/null 2>&1; then
                    emit_event "loop.context_exhaustion" "iteration=$ITERATION" "restart_count=$CONTEXT_RESTART_COUNT" "max_restarts=$MAX_RESTARTS"
                fi
                break
            else
                warn "Context exhaustion detected but restart limit ($CONTEXT_RESTART_LIMIT) reached"
                STATUS="context_exhaustion_fatal"
                write_state
                write_progress
            fi
        fi

        # Mid-loop memory refresh — re-query with current error context after iteration 3
        if [[ "$ITERATION" -ge 3 ]] && type memory_inject_context >/dev/null 2>&1; then
            local refresh_ctx
            refresh_ctx=$(tail -20 "$log_file" 2>/dev/null || true)
            if [[ -n "$refresh_ctx" ]]; then
                local refreshed_memory
                refreshed_memory=$(memory_inject_context "build" "$refresh_ctx" 2>/dev/null | head -5 || true)
                if [[ -n "$refreshed_memory" ]]; then
                    # Append to next iteration's memory context
                    local memory_refresh_file="$LOG_DIR/memory-refresh-${ITERATION}.txt"
                    echo "$refreshed_memory" > "$memory_refresh_file"
                    # Track memory injection for effectiveness measurement
                    if type memeff_on_injection >/dev/null 2>&1; then
                        memeff_on_injection "context_refresh" "${PIPELINE_JOB_ID:-$$}" "build" 2>/dev/null || true
                    fi
                fi
            fi
        fi

        # Auto-commit if Claude didn't
        local commits_before
        commits_before="$(git_commit_count)"
        git_auto_commit "$PROJECT_ROOT" || true
        local commits_after
        commits_after="$(git_commit_count)"
        local new_commits=$(( commits_after - commits_before ))
        TOTAL_COMMITS=$(( TOTAL_COMMITS + new_commits ))

        # Git diff stats
        local diff_stat
        diff_stat="$(git_diff_stat)"
        if [[ -n "$diff_stat" ]]; then
            echo -e "  ${GREEN}✓${RESET} Git: $diff_stat"
        fi

        # Track velocity for adaptive extension budget
        track_iteration_velocity

        # Test gate
        run_test_gate
        write_error_summary
        if [[ -n "$TEST_CMD" ]]; then
            if [[ "$TEST_PASSED" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Tests: passed"
            else
                echo -e "  ${RED}✗${RESET} Tests: failed"
            fi
        fi

        # Dark factory: update RL weights based on test outcome
        if type rl_update_weights >/dev/null 2>&1; then
            if [[ "${TEST_PASSED:-}" == "true" ]]; then
                rl_update_weights "success" 2>/dev/null || true
            elif [[ "${TEST_PASSED:-}" == "false" ]]; then
                rl_update_weights "failure" 2>/dev/null || true
            fi
        fi

        # Track fix outcome for memory effectiveness
        if [[ -n "${_applied_fix_pattern:-}" ]]; then
            if type memory_record_fix_outcome >/dev/null 2>&1; then
                if [[ "${TEST_PASSED:-}" == "true" ]]; then
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "true" 2>/dev/null || true
                else
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "false" 2>/dev/null || true
                fi
            fi
            _applied_fix_pattern=""
        fi

        # Save Claude context for checkpoint resume (goal, findings, test output)
        export SW_LOOP_GOAL="$GOAL"
        export SW_LOOP_ITERATION="$ITERATION"
        export SW_LOOP_STATUS="${STATUS:-running}"
        export SW_LOOP_TEST_OUTPUT="${TEST_OUTPUT:-}"
        export SW_LOOP_FINDINGS="${LOG_ENTRIES:-}"
        # shellcheck disable=SC2155
        export SW_LOOP_MODIFIED="$(git diff --name-only HEAD 2>/dev/null | head -50 | tr '\n' ',' | sed 's/,$//')"
        "$SCRIPT_DIR/sw-checkpoint.sh" save-context --stage build 2>/dev/null || true

        # Audit agent (reviews implementer's work)
        run_audit_agent

        # Verification gap detection: audit failed but tests passed
        # Instead of a full retry (which causes context bloat/timeout), run targeted verification
        if [[ "${AUDIT_RESULT:-}" != "pass" ]] && [[ "${TEST_PASSED:-}" == "true" ]]; then
            echo -e "  ${YELLOW}▸${RESET} Verification gap detected (tests pass, audit disagrees)"

            local verification_passed=true

            # 1. Re-run ALL test commands to double-check
            local recheck_log="${LOG_DIR}/verification-iter-${ITERATION}.log"
            if [[ -n "$TEST_CMD" ]]; then
                eval "$TEST_CMD" > "$recheck_log" 2>&1 || verification_passed=false
            fi
            for _vg_cmd in "${ADDITIONAL_TEST_CMDS[@]+"${ADDITIONAL_TEST_CMDS[@]}"}"; do
                [[ -z "$_vg_cmd" ]] && continue
                eval "$_vg_cmd" >> "$recheck_log" 2>&1 || verification_passed=false
            done

            # 2. Check for uncommitted changes (quality gate)
            if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null; then
                echo -e "  ${YELLOW}⚠${RESET} Uncommitted changes detected"
                verification_passed=false
            fi

            if [[ "$verification_passed" == "true" ]]; then
                echo -e "  ${GREEN}✓${RESET} Verification passed — overriding audit"
                AUDIT_RESULT="pass"
                emit_event "loop.verification_gap_resolved" \
                    "iteration=$ITERATION" "action=override_audit"
                if type audit_emit >/dev/null 2>&1; then
                    audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                        "resolution=override" "tests_recheck=pass" || true
                fi
            else
                echo -e "  ${RED}✗${RESET} Verification failed — audit stands"
                emit_event "loop.verification_gap_confirmed" \
                    "iteration=$ITERATION" "action=retry"
                if type audit_emit >/dev/null 2>&1; then
                    audit_emit "loop.verification_gap" "iteration=$ITERATION" \
                        "resolution=retry" "tests_recheck=fail" || true
                fi
            fi
        fi

        # Auto-commit any remaining changes before quality gates
        # (audit agent, verification handler, or test evidence may create files)
        if ! git -C "$PROJECT_ROOT" diff --quiet 2>/dev/null || \
           ! git -C "$PROJECT_ROOT" diff --cached --quiet 2>/dev/null || \
           [[ -n "$(git -C "$PROJECT_ROOT" ls-files --others --exclude-standard 2>/dev/null | head -1)" ]]; then
            git -C "$PROJECT_ROOT" add -A 2>/dev/null || true
            git -C "$PROJECT_ROOT" commit -m "loop: iteration $ITERATION — post-audit cleanup" --no-verify 2>/dev/null || true
        fi

        # Quality gates (automated checks)
        run_quality_gates

        # Convergence detection (issue #203) — score iteration progress and detect convergence
        if type convergence_integrate >/dev/null 2>&1; then
            local conv_exit=0
            convergence_integrate || conv_exit=$?
            case "$conv_exit" in
                1)
                    # Converged — stop successfully
                    info "Build loop converged — stopping"
                    STATUS="complete"
                    write_state
                    write_progress
                    show_summary
                    return 0
                    ;;
                2)
                    # Diverging — stop with failure
                    warn "Build loop diverging — stopping (scores declining consistently)"
                    STATUS="diverging"
                    write_state
                    write_progress
                    show_summary
                    return 1
                    ;;
                3)
                    # Oscillating — escalate to manual review
                    warn "Build loop oscillating — consider manual review or model escalation"
                    ;;
            esac
        fi

        # Guarded completion (replaces naive grep check)
        if guard_completion; then
            STATUS="complete"
            write_state
            write_progress
            show_summary
            return 0
        fi

        # Check progress (circuit breaker)
        if check_progress; then
            CONSECUTIVE_FAILURES=0
            # Reset auto-recovery state on progress (tests passing, code advancing)
            if type recovery_reset >/dev/null 2>&1; then
                recovery_reset
            fi
            echo -e "  ${GREEN}✓${RESET} Progress detected — continuing"
        else
            CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))
            echo -e "  ${YELLOW}⚠${RESET} Low progress (${CONSECUTIVE_FAILURES}/${CIRCUIT_BREAKER_THRESHOLD} before circuit breaker)"
        fi

        # Extract summary and update state
        local summary
        summary="$(extract_summary "$log_file")"
        append_log_entry "### Iteration $ITERATION ($(now_iso))
$summary
"
        write_state
        write_progress

        # Emit iteration complete event for pipeline visibility
        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.iteration_complete" \
                "iteration=$ITERATION" \
                "max=$MAX_ITERATIONS" \
                "job_id=${PIPELINE_JOB_ID:-loop-$$}" \
                "agent=${AGENT_NUM:-1}" \
                "test_passed=${TEST_PASSED:-unknown}" \
                "commits=$TOTAL_COMMITS" \
                "status=${STATUS:-running}"
        fi

        # Update heartbeat
        "$SCRIPT_DIR/sw-heartbeat.sh" write "${PIPELINE_JOB_ID:-loop-$$}" \
            --pid $$ \
            --stage "build" \
            --iteration "$ITERATION" \
            --activity "Loop iteration $ITERATION" 2>/dev/null || true

        # Human intervention: check for human message between iterations
        local human_msg_file="$STATE_DIR/pipeline-artifacts/human-message.txt"
        if [[ -f "$human_msg_file" ]]; then
            local human_msg
            human_msg="$(cat "$human_msg_file" 2>/dev/null || true)"
            if [[ -n "$human_msg" ]]; then
                echo -e "  ${PURPLE}${BOLD}💬 Human message:${RESET} $human_msg"
                # Inject human message as additional context for next iteration
                GOAL="${GOAL}

HUMAN FEEDBACK (received after iteration $ITERATION): $human_msg"
                rm -f "$human_msg_file"
            fi
        fi

        # Stuckness-triggered restart: if detected 3+ times, break to allow session restart
        if [[ "${STUCKNESS_COUNT:-0}" -ge 3 ]]; then
            STATUS="stuck_restart"
            write_state
            write_progress
            warn "Stuckness detected 3+ times — triggering session restart"
            break
        fi

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done

    # Write final state after loop exits
    write_state
    write_progress
    show_summary
}

# ─── Session Restart Wrapper ─────────────────────────────────────────────────

run_loop_with_restarts() {
    while true; do
        local loop_exit=0
        run_single_agent_loop || loop_exit=$?

        # If completed successfully or no restarts configured, exit
        if [[ "$STATUS" == "complete" ]]; then
            return 0
        fi

        # Context exhaustion: treat as restart, not failure (unless restart limit hit)
        if [[ "$STATUS" == "context_exhaustion_restart" ]]; then
            if [[ "$CONTEXT_RESTART_COUNT" -lt "$CONTEXT_RESTART_LIMIT" ]]; then
                RESTART_COUNT=$(( RESTART_COUNT + 1 ))
                if type emit_event >/dev/null 2>&1; then
                    emit_event "loop.restart" "restart=$RESTART_COUNT" "reason=context_exhaustion" "context_restart=$CONTEXT_RESTART_COUNT" "iteration=$ITERATION"
                fi
                info "Context exhaustion auto-recovery: restart $RESTART_COUNT/$MAX_RESTARTS (context restart $CONTEXT_RESTART_COUNT/$CONTEXT_RESTART_LIMIT)"

                # Capture comprehensive state and generate briefing before restart
                if type restart_before_restart >/dev/null 2>&1; then
                    restart_before_restart || warn "Failed to prepare restart briefing (continuing anyway)"
                fi

                # Reset iteration-level state for fresh session
                SESSION_RESTART=true
                ITERATION=0
                CONSECUTIVE_FAILURES=0
                EXTENSION_COUNT=0
                STUCKNESS_COUNT=0
                STATUS="running"
                LOG_ENTRIES=""
                TEST_PASSED=""
                TEST_OUTPUT=""
                TEST_LOG_FILE=""
                GOAL="$ORIGINAL_GOAL"

                # Archive old artifacts
                local restart_archive="$LOG_DIR/restart-${RESTART_COUNT}"
                mkdir -p "$restart_archive"
                for old_log in "$LOG_DIR"/iteration-*.log "$LOG_DIR"/tests-iter-*.log; do
                    [[ -f "$old_log" ]] && mv "$old_log" "$restart_archive/" 2>/dev/null || true
                done
                [[ -f "$LOG_DIR/progress.md" ]] && cp "$LOG_DIR/progress.md" "$restart_archive/progress.md" 2>/dev/null || true
                [[ -f "$LOG_DIR/error-summary.json" ]] && cp "$LOG_DIR/error-summary.json" "$restart_archive/" 2>/dev/null || true

                write_state
                sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
                continue
            else
                warn "Context exhaustion limit reached — failing build"
                return "$loop_exit"
            fi
        fi

        if [[ "$MAX_RESTARTS" -le 0 ]]; then
            return "$loop_exit"
        fi
        if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
            warn "Max restarts ($MAX_RESTARTS) reached — stopping"
            return "$loop_exit"
        fi
        # Hard cap safety net (configurable)
        local _hard_cap
        _hard_cap=$(_smart_int "loop.hard_restart_cap" 5)
        if [[ "$RESTART_COUNT" -ge "$_hard_cap" ]]; then
            warn "Hard restart cap ($_hard_cap) reached — stopping"
            return "$loop_exit"
        fi

        # Check if tests are still failing (worth restarting)
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            info "Tests passing but loop incomplete — restarting session"
        else
            info "Tests failing and loop exhausted — restarting with fresh context"
        fi

        RESTART_COUNT=$(( RESTART_COUNT + 1 ))

        # Capture comprehensive state and generate briefing before restart
        if type restart_before_restart >/dev/null 2>&1; then
            restart_before_restart || warn "Failed to prepare restart briefing (continuing anyway)"
        fi

        if type emit_event >/dev/null 2>&1; then
            emit_event "loop.restart" "restart=$RESTART_COUNT" "max=$MAX_RESTARTS" "iteration=$ITERATION"
        fi
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — resetting iteration counter"

        # Reset ALL iteration-level state for the new session
        # SESSION_RESTART tells run_single_agent_loop to skip init/resume
        SESSION_RESTART=true
        ITERATION=0
        CONSECUTIVE_FAILURES=0
        EXTENSION_COUNT=0
        STUCKNESS_COUNT=0
        STATUS="running"
        LOG_ENTRIES=""
        TEST_PASSED=""
        TEST_OUTPUT=""
        TEST_LOG_FILE=""
        # Reset GOAL to original — prevent unbounded growth from memory/human injections
        GOAL="$ORIGINAL_GOAL"

        # Archive old artifacts so they don't get overwritten or pollute new session
        local restart_archive="$LOG_DIR/restart-${RESTART_COUNT}"
        mkdir -p "$restart_archive"
        for old_log in "$LOG_DIR"/iteration-*.log "$LOG_DIR"/tests-iter-*.log; do
            [[ -f "$old_log" ]] && mv "$old_log" "$restart_archive/" 2>/dev/null || true
        done
        # Archive progress.md and error-summary.json from previous session
        # IMPORTANT: copy (not move) error-summary.json so the fresh session can still read it
        [[ -f "$LOG_DIR/progress.md" ]] && cp "$LOG_DIR/progress.md" "$restart_archive/progress.md" 2>/dev/null || true
        [[ -f "$LOG_DIR/error-summary.json" ]] && cp "$LOG_DIR/error-summary.json" "$restart_archive/" 2>/dev/null || true

        write_state

        sleep "$(_config_get_int "loop.sleep_between_iterations" 2 2>/dev/null || echo 2)"
    done
}

# ─── Main: Entry Point ───────────────────────────────────────────────────────

main() {
    if [[ "$AGENTS" -gt 1 ]]; then
        if $RESUME; then
            resume_state
        else
            initialize_state
        fi
        show_banner
        launch_multi_agent
        show_summary
    else
        run_loop_with_restarts
    fi
}

main
