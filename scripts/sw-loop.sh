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
# Loop sub-modules: iteration execution, convergence detection, session
# management. These hold most of the loop, so a missing or stale copy is fatal
# up front rather than a "command not found" halfway through an iteration.
for _loop_mod in loop-iteration loop-convergence loop-session; do
    if [[ ! -f "$SCRIPT_DIR/lib/${_loop_mod}.sh" ]]; then
        echo "ERROR: missing $SCRIPT_DIR/lib/${_loop_mod}.sh — reinstall shipwright" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/lib/${_loop_mod}.sh"
done
unset _loop_mod
if ! type run_single_agent_loop guard_completion loop_session_init >/dev/null 2>&1; then
    echo "ERROR: stale $SCRIPT_DIR/lib/loop-*.sh (older than sw-loop.sh) — reinstall shipwright" >&2
    exit 1
fi
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

# ─── Progress Velocity Tracking ─────────────────────────────────────────────
ITERATION_LINES_CHANGED=""
VELOCITY_HISTORY=""

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

# Git helpers, model selection and the iteration loop itself live in
# lib/loop-iteration.sh; failure diagnosis, quality gates and guarded
# completion in lib/loop-convergence.sh; restarts, multi-agent sessions and
# the banner/summary in lib/loop-session.sh.

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

    # Use structured output for machine-parseable audit results
    local schema_file="${SCRIPT_DIR}/../schemas/audit-result.json"
    if [[ -f "$schema_file" ]]; then
        audit_flags+=("--json-schema" "$(cat "$schema_file")")
    fi

    local exit_code=0
    claude -p "$audit_prompt" "${audit_flags[@]}" > "$audit_log" 2>&1 || exit_code=$?

    if grep -q "AUDIT_PASS" "$audit_log" 2>/dev/null; then
        AUDIT_RESULT="pass"
        echo -e "  ${GREEN}✓${RESET} Audit: passed"
    else
        AUDIT_RESULT="$(grep -v '^$' "$audit_log" | tail -20 | head -10 2>/dev/null || echo "Audit returned no output")"
        echo -e "  ${YELLOW}⚠${RESET} Audit: issues found"
    fi
}

# ─── Verification Gap ────────────────────────────────────────────────────────
# Audit failed but tests passed. Instead of a full retry (which causes context
# bloat/timeout), re-run every test command and check the tree is committed;
# if both hold, override the audit. Called from run_single_agent_loop.
handle_verification_gap() {
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
}

# ─── Stuckness Detection ─────────────────────────────────────────────────────
# State for detect_stuckness (lib/loop-convergence.sh). When stuck it
# increments STUCKNESS_COUNT; at >= 3 the caller triggers a session restart.
STUCKNESS_COUNT=0
STUCKNESS_TRACKING_FILE=""

# ─── Prompt Composition ──────────────────────────────────────────────────────
# compose_prompt() lives in lib/loop-iteration.sh.

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

# ─── Multi-Agent ─────────────────────────────────────────────────────────────
# Worker sessions are launched by launch_multi_agent (lib/loop-session.sh).
MULTI_WINDOW_NAME=""

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
