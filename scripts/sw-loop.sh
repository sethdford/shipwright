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
MAX_RESTARTS=0
SESSION_RESTART=false
RESTART_COUNT=0
REPO_OVERRIDE=""
VERSION="2.2.1"

# ─── Token Tracking ─────────────────────────────────────────────────────────
LOOP_INPUT_TOKENS=0
LOOP_OUTPUT_TOKENS=0
LOOP_COST_MILLICENTS=0

# ─── Flexible Iteration Defaults ────────────────────────────────────────────
AUTO_EXTEND=true          # Auto-extend iterations when work is incomplete
EXTENSION_SIZE=5          # Additional iterations per extension
MAX_EXTENSIONS=3          # Max number of extensions (hard cap safety net)
EXTENSION_COUNT=0         # Current number of extensions applied

# ─── Circuit Breaker Defaults ──────────────────────────────────────────────
CIRCUIT_BREAKER_THRESHOLD=3       # Consecutive low-progress iterations before stopping
MIN_PROGRESS_LINES=5              # Minimum insertions to count as progress

# ─── Audit & Quality Gate Defaults ───────────────────────────────────────────
AUDIT_ENABLED=false
AUDIT_AGENT_ENABLED=false
DOD_FILE=""
QUALITY_GATES_ENABLED=false
AUDIT_RESULT=""
COMPLETION_REJECTED=false
QUALITY_GATE_PASSED=true

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
    echo -e "  ${CYAN}--model${RESET} MODEL             Claude model to use (default: opus)"
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

if ! command -v claude &>/dev/null; then
    error "Claude Code CLI not found. Install it first:"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    exit 1
fi

if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    error "Not inside a git repository. The loop requires git for progress tracking."
    exit 1
fi

# Preserve original goal before any appending (memory fixes, human feedback)
ORIGINAL_GOAL="$GOAL"

# ─── Timeout Detection ────────────────────────────────────────────────────────
TIMEOUT_CMD=""
if command -v timeout &>/dev/null; then
    TIMEOUT_CMD="timeout"
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD="gtimeout"
fi
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-1800}"  # 30 min default

if [[ "$AGENTS" -gt 1 ]]; then
    if ! command -v tmux &>/dev/null; then
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
    if [[ -f "$_routing_file" ]] && command -v jq &>/dev/null; then
        local _routed_model
        _routed_model=$(jq -r --arg r "$role" '.routes[$r].model // ""' "$_routing_file" 2>/dev/null) || true
        if [[ -n "${_routed_model:-}" && "${_routed_model:-}" != "null" ]]; then
            echo "${_routed_model}"
            return 0
        fi
    fi

    # Try intelligence-based recommendation
    if type intelligence_recommend_model &>/dev/null 2>&1; then
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
    local default_model="haiku"
    local opt_file="$HOME/.shipwright/optimization/audit-tuning.json"
    if [[ -f "$opt_file" ]] && command -v jq &>/dev/null; then
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
    if command -v jq &>/dev/null && head -c1 "$log_file" 2>/dev/null | grep -q '\['; then
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

    # Case 2: Valid JSON array — extract .result from last element
    if [[ "$first_char" == "[" ]] && command -v jq &>/dev/null; then
        local extracted
        extracted=$(jq -r '.[-1].result // empty' "$json_file" 2>/dev/null) || true
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # jq succeeded but result was null/empty — try .content or raw text
        extracted=$(jq -r '.[].content // empty' "$json_file" 2>/dev/null | head -500) || true
        if [[ -n "$extracted" ]]; then
            echo "$extracted" > "$log_file"
            return 0
        fi
        # JSON parsed but no text found — write placeholder
        warn "JSON output has no .result field — check $json_file"
        echo "(no text result in JSON output)" > "$log_file"
        return 0
    fi

    # Case 3: Looks like JSON but no jq — can't parse, use raw
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
    cat > "$tmp_file" <<TOKJSON
{"input_tokens":${LOOP_INPUT_TOKENS},"output_tokens":${LOOP_OUTPUT_TOKENS},"cost_usd":${cost_usd},"iterations":${ITERATION:-0}}
TOKJSON
    mv "$tmp_file" "$token_file"
}

# ─── Adaptive Iteration Budget ──────────────────────────────────────────────
# Reads tuning config for smarter iteration/circuit-breaker thresholds.
apply_adaptive_budget() {
    local tuning_file="$HOME/.shipwright/optimization/loop-tuning.json"
    if [[ -f "$tuning_file" ]] && command -v jq &>/dev/null; then
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
    if [[ -f "$_iter_model" ]] && ! $MAX_ITERATIONS_EXPLICIT && command -v jq &>/dev/null; then
        local _complexity="${ISSUE_COMPLEXITY:-${COMPLEXITY:-medium}}"
        local _predicted_max
        _predicted_max=$(jq -r --arg c "$_complexity" '.predictions[$c].max_iterations // ""' "$_iter_model" 2>/dev/null) || true
        if [[ -n "${_predicted_max:-}" && "${_predicted_max:-}" != "null" && "${_predicted_max:-0}" -gt 0 ]]; then
            MAX_ITERATIONS="${_predicted_max}"
            info "Iteration model: ${_complexity} complexity → max ${_predicted_max} iterations"
        fi
    fi

    # Try intelligence-based iteration estimate
    if type intelligence_estimate_iterations &>/dev/null 2>&1 && ! $MAX_ITERATIONS_EXPLICIT; then
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

track_iteration_velocity() {
    local changes
    changes="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null | tail -1 || echo "")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    ITERATION_LINES_CHANGED="${insertions:-0}"
    if [[ -n "$VELOCITY_HISTORY" ]]; then
        VELOCITY_HISTORY="${VELOCITY_HISTORY},${ITERATION_LINES_CHANGED}"
    else
        VELOCITY_HISTORY="${ITERATION_LINES_CHANGED}"
    fi
}

# Compute average lines/iteration from recent history
compute_velocity_avg() {
    if [[ -z "$VELOCITY_HISTORY" ]]; then
        echo "0"
        return 0
    fi
    local total=0 count=0
    local IFS=','
    local val
    for val in $VELOCITY_HISTORY; do
        total=$((total + val))
        count=$((count + 1))
    done
    if [[ "$count" -gt 0 ]]; then
        echo $((total / count))
    else
        echo "0"
    fi
}

# ─── Timing Helpers ───────────────────────────────────────────────────────────

now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

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

initialize_state() {
    ITERATION=0
    CONSECUTIVE_FAILURES=0
    TOTAL_COMMITS=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"
    LOG_ENTRIES=""

    write_state
}

resume_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        error "No state file found at $STATE_FILE"
        echo -e "  Start a new loop instead: ${DIM}shipwright loop \"<goal>\"${RESET}"
        exit 1
    fi

    info "Resuming from $STATE_FILE"

    # Save CLI values before parsing state (CLI takes precedence)
    local cli_max_iterations="$MAX_ITERATIONS"

    # Parse YAML front matter
    local in_frontmatter=false
    while IFS= read -r line; do
        if [[ "$line" == "---" ]]; then
            if $in_frontmatter; then
                break
            else
                in_frontmatter=true
                continue
            fi
        fi
        if $in_frontmatter; then
            case "$line" in
                goal:*)          [[ -z "$GOAL" ]] && GOAL="$(echo "${line#goal:}" | sed 's/^ *"//;s/" *$//')" ;;
                iteration:*)     ITERATION="$(echo "${line#iteration:}" | tr -d ' ')" ;;
                max_iterations:*) MAX_ITERATIONS="$(echo "${line#max_iterations:}" | tr -d ' ')" ;;
                status:*)        STATUS="$(echo "${line#status:}" | tr -d ' ')" ;;
                test_cmd:*)      [[ -z "$TEST_CMD" ]] && TEST_CMD="$(echo "${line#test_cmd:}" | sed 's/^ *"//;s/" *$//')" ;;
                model:*)         MODEL="$(echo "${line#model:}" | tr -d ' ')" ;;
                agents:*)        AGENTS="$(echo "${line#agents:}" | tr -d ' ')" ;;
                consecutive_failures:*) CONSECUTIVE_FAILURES="$(echo "${line#consecutive_failures:}" | tr -d ' ')" ;;
                total_commits:*) TOTAL_COMMITS="$(echo "${line#total_commits:}" | tr -d ' ')" ;;
                audit_enabled:*)         AUDIT_ENABLED="$(echo "${line#audit_enabled:}" | tr -d ' ')" ;;
                audit_agent_enabled:*)   AUDIT_AGENT_ENABLED="$(echo "${line#audit_agent_enabled:}" | tr -d ' ')" ;;
                quality_gates_enabled:*) QUALITY_GATES_ENABLED="$(echo "${line#quality_gates_enabled:}" | tr -d ' ')" ;;
                dod_file:*)              DOD_FILE="$(echo "${line#dod_file:}" | sed 's/^ *"//;s/" *$//')" ;;
                auto_extend:*)           AUTO_EXTEND="$(echo "${line#auto_extend:}" | tr -d ' ')" ;;
                extension_count:*)       EXTENSION_COUNT="$(echo "${line#extension_count:}" | tr -d ' ')" ;;
                max_extensions:*)        MAX_EXTENSIONS="$(echo "${line#max_extensions:}" | tr -d ' ')" ;;
            esac
        fi
    done < "$STATE_FILE"

    # CLI --max-iterations overrides state file
    if $MAX_ITERATIONS_EXPLICIT; then
        MAX_ITERATIONS="$cli_max_iterations"
    fi

    # Extract the log section (everything after ## Log)
    LOG_ENTRIES="$(sed -n '/^## Log$/,$ { /^## Log$/d; p; }' "$STATE_FILE" 2>/dev/null || true)"

    if [[ -z "$GOAL" ]]; then
        error "Could not parse goal from state file."
        exit 1
    fi

    if [[ "$STATUS" == "complete" ]]; then
        warn "Previous loop completed. Start a new one or edit the state file."
        exit 0
    fi

    # Reset circuit breaker on resume
    CONSECUTIVE_FAILURES=0
    START_EPOCH="$(now_epoch)"
    STATUS="running"

    # If we hit max iterations before, warn user to extend
    if [[ "$ITERATION" -ge "$MAX_ITERATIONS" ]] && ! $MAX_ITERATIONS_EXPLICIT; then
        warn "Previous run stopped at iteration $ITERATION/$MAX_ITERATIONS."
        echo -e "  Extend with: ${DIM}shipwright loop --resume --max-iterations $(( MAX_ITERATIONS + 10 ))${RESET}"
        exit 0
    fi

    success "Resumed: iteration $ITERATION/$MAX_ITERATIONS"
}

write_state() {
    local tmp_state="${STATE_FILE}.tmp.$$"
    # Use printf instead of heredoc to avoid delimiter injection from GOAL
    {
        printf -- '---\n'
        printf 'goal: "%s"\n' "$GOAL"
        printf 'iteration: %s\n' "$ITERATION"
        printf 'max_iterations: %s\n' "$MAX_ITERATIONS"
        printf 'status: %s\n' "$STATUS"
        printf 'test_cmd: "%s"\n' "$TEST_CMD"
        printf 'model: %s\n' "$MODEL"
        printf 'agents: %s\n' "$AGENTS"
        printf 'started_at: %s\n' "$(now_iso)"
        printf 'last_iteration_at: %s\n' "$(now_iso)"
        printf 'consecutive_failures: %s\n' "$CONSECUTIVE_FAILURES"
        printf 'total_commits: %s\n' "$TOTAL_COMMITS"
        printf 'audit_enabled: %s\n' "$AUDIT_ENABLED"
        printf 'audit_agent_enabled: %s\n' "$AUDIT_AGENT_ENABLED"
        printf 'quality_gates_enabled: %s\n' "$QUALITY_GATES_ENABLED"
        printf 'dod_file: "%s"\n' "$DOD_FILE"
        printf 'auto_extend: %s\n' "$AUTO_EXTEND"
        printf 'extension_count: %s\n' "$EXTENSION_COUNT"
        printf 'max_extensions: %s\n' "$MAX_EXTENSIONS"
        printf -- '---\n\n'
        printf '## Log\n'
        printf '%s\n' "$LOG_ENTRIES"
    } > "$tmp_state"
    if ! mv "$tmp_state" "$STATE_FILE" 2>/dev/null; then
        warn "Failed to write state file: $STATE_FILE"
    fi
}

write_progress() {
    local progress_file="$LOG_DIR/progress.md"
    local recent_commits
    recent_commits=$(git -C "$PROJECT_ROOT" log --oneline -5 2>/dev/null || echo "(no commits)")
    local changed_files
    changed_files=$(git -C "$PROJECT_ROOT" diff --name-only HEAD~3 2>/dev/null | head -20 || echo "(none)")
    local last_error=""
    local prev_test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
    if [[ -f "$prev_test_log" ]] && [[ "${TEST_PASSED:-}" == "false" ]]; then
        last_error=$(tail -10 "$prev_test_log" 2>/dev/null || true)
    fi

    # Use printf to avoid heredoc delimiter injection from GOAL content
    local tmp_progress="${progress_file}.tmp.$$"
    {
        printf '# Session Progress (Auto-Generated)\n\n'
        printf '## Goal\n%s\n\n' "${GOAL}"
        printf '## Status\n'
        printf -- '- Iteration: %s/%s\n' "${ITERATION}" "${MAX_ITERATIONS}"
        printf -- '- Session restart: %s/%s\n' "${RESTART_COUNT:-0}" "${MAX_RESTARTS:-0}"
        printf -- '- Tests passing: %s\n' "${TEST_PASSED:-unknown}"
        printf -- '- Status: %s\n\n' "${STATUS:-running}"
        printf '## Recent Commits\n%s\n\n' "${recent_commits}"
        printf '## Changed Files\n%s\n\n' "${changed_files}"
        if [[ -n "$last_error" ]]; then
            printf '## Last Error\n%s\n\n' "$last_error"
        fi
        printf '## Timestamp\n%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "$tmp_progress" 2>/dev/null
    mv "$tmp_progress" "$progress_file" 2>/dev/null || rm -f "$tmp_progress" 2>/dev/null
}

append_log_entry() {
    local entry="$1"
    if [[ -n "$LOG_ENTRIES" ]]; then
        LOG_ENTRIES="${LOG_ENTRIES}
${entry}"
    else
        LOG_ENTRIES="$entry"
    fi
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
    git -C "$work_dir" commit -m "loop: iteration $ITERATION — autonomous progress" --no-verify 2>/dev/null || return 1
    return 0
}

# ─── Fatal Error Detection ────────────────────────────────────────────────────

check_fatal_error() {
    local log_file="$1"
    local cli_exit_code="${2:-0}"
    [[ -f "$log_file" ]] || return 1

    # Known fatal error patterns from Claude CLI / Anthropic API
    local fatal_patterns="Invalid API key|invalid_api_key|authentication_error|API key expired"
    fatal_patterns="${fatal_patterns}|rate_limit_error|overloaded_error|billing"
    fatal_patterns="${fatal_patterns}|Could not resolve host|connection refused|ECONNREFUSED"
    fatal_patterns="${fatal_patterns}|ANTHROPIC_API_KEY.*not set|No API key"

    if grep -qiE "$fatal_patterns" "$log_file" 2>/dev/null; then
        local match
        match=$(grep -iE "$fatal_patterns" "$log_file" 2>/dev/null | head -1 | cut -c1-120)
        error "Fatal CLI error: $match"
        return 0  # fatal error detected
    fi

    # Non-zero exit + tiny output = likely CLI crash
    if [[ "$cli_exit_code" -ne 0 ]]; then
        local line_count
        line_count=$(grep -cv '^$' "$log_file" 2>/dev/null || echo 0)
        if [[ "$line_count" -lt 3 ]]; then
            local content
            content=$(head -3 "$log_file" 2>/dev/null | cut -c1-120)
            error "CLI exited $cli_exit_code with minimal output: $content"
            return 0
        fi
    fi

    return 1  # no fatal error
}

# ─── Progress & Circuit Breaker ───────────────────────────────────────────────

check_progress() {
    local changes
    # Exclude loop bookkeeping files — only count real code changes as progress
    changes="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 \
        -- . ':!.claude/loop-state.md' ':!.claude/pipeline-state.md' \
        ':!**/progress.md' ':!**/error-summary.json' \
        2>/dev/null | tail -1 || echo "")"
    local insertions
    insertions="$(echo "$changes" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    if [[ "${insertions:-0}" -lt "$MIN_PROGRESS_LINES" ]]; then
        return 1  # No meaningful progress
    fi
    return 0
}

check_completion() {
    local log_file="$1"
    grep -q "LOOP_COMPLETE" "$log_file" 2>/dev/null
}

check_circuit_breaker() {
    # Vitals-driven circuit breaker (preferred over static threshold)
    if type pipeline_compute_vitals &>/dev/null 2>&1 && type pipeline_health_verdict &>/dev/null 2>&1; then
        local _vitals_json _verdict
        local _loop_state="${STATE_FILE:-}"
        local _loop_artifacts="${ARTIFACTS_DIR:-}"
        local _loop_issue="${ISSUE_NUMBER:-}"
        _vitals_json=$(pipeline_compute_vitals "$_loop_state" "$_loop_artifacts" "$_loop_issue" 2>/dev/null) || true
        if [[ -n "$_vitals_json" && "$_vitals_json" != "{}" ]]; then
            _verdict=$(echo "$_vitals_json" | jq -r '.verdict // "continue"' 2>/dev/null || echo "continue")
            if [[ "$_verdict" == "abort" ]]; then
                local _health_score
                _health_score=$(echo "$_vitals_json" | jq -r '.health_score // 0' 2>/dev/null || echo "0")
                error "Vitals circuit breaker: health score ${_health_score}/100 — aborting (${CONSECUTIVE_FAILURES} stagnant iterations)"
                STATUS="circuit_breaker"
                return 1
            fi
            # Vitals say continue/warn/intervene — don't trip circuit breaker yet
            if [[ "$_verdict" == "continue" || "$_verdict" == "warn" ]]; then
                return 0
            fi
        fi
    fi

    # Fallback: static threshold circuit breaker
    if [[ "$CONSECUTIVE_FAILURES" -ge "$CIRCUIT_BREAKER_THRESHOLD" ]]; then
        error "Circuit breaker tripped: ${CIRCUIT_BREAKER_THRESHOLD} consecutive iterations with no meaningful progress."
        STATUS="circuit_breaker"
        return 1
    fi
    return 0
}

check_max_iterations() {
    if [[ "$ITERATION" -le "$MAX_ITERATIONS" ]]; then
        return 0
    fi

    # Hit the cap — check if we should auto-extend
    if ! $AUTO_EXTEND || [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
        if [[ "$EXTENSION_COUNT" -ge "$MAX_EXTENSIONS" ]]; then
            warn "Hard cap reached: ${EXTENSION_COUNT} extensions applied (max ${MAX_EXTENSIONS})."
        fi
        warn "Max iterations ($MAX_ITERATIONS) reached."
        STATUS="max_iterations"
        return 1
    fi

    # Checkpoint audit: is there meaningful progress worth extending for?
    echo -e "\n  ${CYAN}${BOLD}▸ Checkpoint${RESET} — max iterations ($MAX_ITERATIONS) reached, evaluating progress..."

    local should_extend=false
    local extension_reason=""

    # Check 1: recent meaningful progress (not stuck)
    if [[ "${CONSECUTIVE_FAILURES:-0}" -lt 2 ]]; then
        # Check 2: agent hasn't signaled completion (if it did, guard_completion handles it)
        local last_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
        if [[ -f "$last_log" ]] && ! grep -q "LOOP_COMPLETE" "$last_log" 2>/dev/null; then
            should_extend=true
            extension_reason="work in progress with recent progress"
        fi
    fi

    # Check 3: if quality gates or tests are failing, extend to let agent fix them
    if [[ "$TEST_PASSED" == "false" ]] || ! $QUALITY_GATE_PASSED; then
        should_extend=true
        extension_reason="quality gates or tests not yet passing"
    fi

    if $should_extend; then
        # Scale extension size by velocity — good progress earns more iterations
        local velocity_avg
        velocity_avg="$(compute_velocity_avg)"
        local effective_extension="$EXTENSION_SIZE"
        if [[ "$velocity_avg" -gt 20 ]]; then
            # High velocity: grant more iterations
            effective_extension=$(( EXTENSION_SIZE + 3 ))
        elif [[ "$velocity_avg" -lt 5 ]]; then
            # Low velocity: grant fewer iterations
            effective_extension=$(( EXTENSION_SIZE > 2 ? EXTENSION_SIZE - 2 : 1 ))
        fi
        EXTENSION_COUNT=$(( EXTENSION_COUNT + 1 ))
        MAX_ITERATIONS=$(( MAX_ITERATIONS + effective_extension ))
        echo -e "  ${GREEN}✓${RESET} Auto-extending: +${effective_extension} iterations (now ${MAX_ITERATIONS} max, extension ${EXTENSION_COUNT}/${MAX_EXTENSIONS})"
        echo -e "  ${DIM}Reason: ${extension_reason} | velocity: ~${velocity_avg} lines/iter${RESET}"
        return 0
    fi

    warn "Max iterations reached — no recent progress detected."
    STATUS="max_iterations"
    return 1
}

# ─── Test Gate ────────────────────────────────────────────────────────────────

run_test_gate() {
    if [[ -z "$TEST_CMD" ]]; then
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

    local test_log="$LOG_DIR/tests-iter-${ITERATION}.log"
    TEST_LOG_FILE="$test_log"
    echo -e "  ${DIM}Running ${test_mode} tests...${RESET}"
    # Wrap test command with timeout (5 min default) to prevent hanging
    local test_timeout="${SW_TEST_TIMEOUT:-300}"
    local test_wrapper="$active_test_cmd"
    if command -v timeout &>/dev/null; then
        test_wrapper="timeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
    elif command -v gtimeout &>/dev/null; then
        test_wrapper="gtimeout ${test_timeout} bash -c $(printf '%q' "$active_test_cmd")"
    fi
    if bash -c "$test_wrapper" > "$test_log" 2>&1; then
        TEST_PASSED=true
        TEST_OUTPUT="All tests passed (${test_mode} mode)."
    else
        TEST_PASSED=false
        TEST_OUTPUT="$(tail -50 "$test_log")"
    fi
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
    if command -v jq &>/dev/null; then
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

    # Gather context: tail of implementer output + git diff
    local impl_tail
    impl_tail="$(tail -100 "$log_file" 2>/dev/null || echo "(no output)")"
    local diff_stat
    diff_stat="$(git -C "$PROJECT_ROOT" diff --stat HEAD~1 2>/dev/null || echo "(no changes)")"

    local audit_prompt
    read -r -d '' audit_prompt <<AUDIT_PROMPT || true
You are an independent code auditor reviewing an autonomous coding agent.

## Goal the agent was working toward
${GOAL}

## Agent Output (last 100 lines)
${impl_tail}

## Changes Made (git diff --stat)
${diff_stat}

## Your Task
Critically review the work:
1. Did the agent make meaningful progress toward the goal?
2. Are there obvious bugs, logic errors, or security issues?
3. Did the agent leave incomplete work (TODOs, placeholder code)?
4. Are there any regressions or broken patterns?
5. Is the code quality acceptable?

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

    # Gate 3: No TODO/FIXME/HACK/XXX in new code
    local todo_count
    todo_count="$(git -C "$PROJECT_ROOT" diff HEAD~1 2>/dev/null | grep -cE '^\+.*(TODO|FIXME|HACK|XXX)' || true)"
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
    local diff_content
    diff_content="$(git -C "$PROJECT_ROOT" diff HEAD~1 2>/dev/null || echo "(no diff)")"

    local dod_prompt
    read -r -d '' dod_prompt <<DOD_PROMPT || true
You are evaluating whether code changes satisfy a Definition of Done checklist.

## Definition of Done
${dod_content}

## Changes Made (git diff)
${diff_content}

## Your Task
For each item in the Definition of Done, determine if the changes satisfy it.
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

# ─── Prompt Composition ──────────────────────────────────────────────────────

compose_prompt() {
    local recent_log
    # Get last 3 iteration summaries from log entries
    recent_log="$(echo "$LOG_ENTRIES" | tail -15)"
    if [[ -z "$recent_log" ]]; then
        recent_log="(first iteration — no previous progress)"
    fi

    local git_log
    git_log="$(git_recent_log)"

    local test_section
    if [[ -z "$TEST_CMD" ]]; then
        test_section="No test command configured."
    elif [[ -z "$TEST_PASSED" ]]; then
        test_section="No test results yet (first iteration). Test command: $TEST_CMD"
    elif $TEST_PASSED; then
        test_section="$TEST_OUTPUT"
    else
        test_section="TESTS FAILED — fix these before proceeding:
$TEST_OUTPUT"
    fi

    # Structured error context (machine-readable)
    local error_summary_section=""
    local error_json="$LOG_DIR/error-summary.json"
    if [[ -f "$error_json" ]]; then
        local err_count err_lines
        err_count=$(jq -r '.error_count // 0' "$error_json" 2>/dev/null || echo "0")
        err_lines=$(jq -r '.error_lines[]? // empty' "$error_json" 2>/dev/null | head -10 || true)
        if [[ "$err_count" -gt 0 ]] && [[ -n "$err_lines" ]]; then
            error_summary_section="## Structured Error Summary (${err_count} errors detected)
${err_lines}

Fix these specific errors. Each line above is one distinct error from the test output."
        fi
    fi

    # Build audit sections (captured before heredoc to avoid nested heredoc issues)
    local audit_section
    audit_section="$(compose_audit_section)"
    local audit_feedback_section
    audit_feedback_section="$(compose_audit_feedback_section)"
    local rejection_notice_section
    rejection_notice_section="$(compose_rejection_notice_section)"

    # Memory context injection (failure patterns + past learnings)
    local memory_section=""
    if type memory_inject_context &>/dev/null 2>&1; then
        memory_section="$(memory_inject_context "build" 2>/dev/null || true)"
    elif [[ -f "$SCRIPT_DIR/sw-memory.sh" ]]; then
        memory_section="$("$SCRIPT_DIR/sw-memory.sh" inject build 2>/dev/null || true)"
    fi

    # DORA baselines for context
    local dora_section=""
    if type memory_get_dora_baseline &>/dev/null 2>&1; then
        local dora_json
        dora_json="$(memory_get_dora_baseline 7 2>/dev/null || echo "{}")"
        local dora_total
        dora_total=$(echo "$dora_json" | jq -r '.total // 0' 2>/dev/null || echo "0")
        if [[ "$dora_total" -gt 0 ]]; then
            local dora_df dora_cfr
            dora_df=$(echo "$dora_json" | jq -r '.deploy_freq // 0' 2>/dev/null || echo "0")
            dora_cfr=$(echo "$dora_json" | jq -r '.cfr // 0' 2>/dev/null || echo "0")
            dora_section="## Performance Baselines (Last 7 Days)
- Deploy frequency: ${dora_df}/week
- Change failure rate: ${dora_cfr}%
- Total pipeline runs: ${dora_total}"
        fi
    fi

    # Append mid-loop memory refresh if available
    local memory_refresh_file="$LOG_DIR/memory-refresh-$(( ITERATION - 1 )).txt"
    if [[ -f "$memory_refresh_file" ]]; then
        memory_section="${memory_section}

## Fresh Context (from iteration $(( ITERATION - 1 )) analysis)
$(cat "$memory_refresh_file")"
    fi

    # GitHub intelligence context (gated by availability)
    local intelligence_section=""
    if [[ "${NO_GITHUB:-}" != "true" ]]; then
        # File hotspots — top 5 most-changed files
        if type gh_file_change_frequency &>/dev/null 2>&1; then
            local hotspots
            hotspots=$(gh_file_change_frequency 2>/dev/null | head -5 || true)
            if [[ -n "$hotspots" ]]; then
                intelligence_section="${intelligence_section}
## File Hotspots (most frequently changed)
${hotspots}"
            fi
        fi

        # CODEOWNERS context
        if type gh_codeowners &>/dev/null 2>&1; then
            local owners
            owners=$(gh_codeowners 2>/dev/null | head -10 || true)
            if [[ -n "$owners" ]]; then
                intelligence_section="${intelligence_section}
## Code Owners
${owners}"
            fi
        fi

        # Active security alerts
        if type gh_security_alerts &>/dev/null 2>&1; then
            local alerts
            alerts=$(gh_security_alerts 2>/dev/null | head -5 || true)
            if [[ -n "$alerts" ]]; then
                intelligence_section="${intelligence_section}
## Active Security Alerts
${alerts}"
            fi
        fi
    fi

    # Architecture rules (from intelligence layer)
    local repo_hash
    repo_hash=$(echo -n "$(pwd)" | shasum -a 256 2>/dev/null | cut -c1-12 || echo "unknown")
    local arch_file="${HOME}/.shipwright/memory/${repo_hash}/architecture.json"
    if [[ -f "$arch_file" ]]; then
        local arch_rules
        arch_rules=$(jq -r '.rules[]? // empty' "$arch_file" 2>/dev/null | head -10 || true)
        if [[ -n "$arch_rules" ]]; then
            intelligence_section="${intelligence_section}
## Architecture Rules
${arch_rules}"
        fi
    fi

    # Coverage baseline
    local coverage_file="${HOME}/.shipwright/baselines/${repo_hash}/coverage.json"
    if [[ -f "$coverage_file" ]]; then
        local coverage_pct
        coverage_pct=$(jq -r '.coverage_percent // empty' "$coverage_file" 2>/dev/null || true)
        if [[ -n "$coverage_pct" ]]; then
            intelligence_section="${intelligence_section}
## Coverage Baseline
Current coverage: ${coverage_pct}% — do not decrease this."
        fi
    fi

    # Error classification from last failure
    local error_log=".claude/pipeline-artifacts/error-log.jsonl"
    if [[ -f "$error_log" ]]; then
        local last_error
        last_error=$(tail -1 "$error_log" 2>/dev/null | jq -r '"Type: \(.type), Exit: \(.exit_code), Error: \(.error | split("\n") | first)"' 2>/dev/null || true)
        if [[ -n "$last_error" ]]; then
            intelligence_section="${intelligence_section}
## Last Error Context
${last_error}"
        fi
    fi

    # Stuckness detection — compare last 3 iteration outputs
    local stuckness_section=""
    stuckness_section="$(detect_stuckness)"

    # Session restart context — inject previous session progress
    local restart_section=""
    if [[ "$SESSION_RESTART" == "true" ]] && [[ -f "$LOG_DIR/progress.md" ]]; then
        restart_section="## Previous Session Progress
$(cat "$LOG_DIR/progress.md")

You are starting a FRESH session after the previous one exhausted its iterations.
Read the progress above and continue from where it left off. Do NOT repeat work already done."
    fi

    cat <<PROMPT
You are an autonomous coding agent on iteration ${ITERATION}/${MAX_ITERATIONS} of a continuous loop.

## Your Goal
${GOAL}

## Current Progress
${recent_log}

## Recent Git Activity
${git_log}

## Test Results (Previous Iteration)
${test_section}

${error_summary_section:+$error_summary_section
}
${memory_section:+## Memory Context
$memory_section
}
${dora_section:+$dora_section
}
${intelligence_section:+$intelligence_section
}
${restart_section:+$restart_section
}
## Instructions
1. Read the codebase and understand the current state
2. Identify the highest-priority remaining work toward the goal
3. Implement ONE meaningful chunk of progress
4. Run tests if a test command exists: ${TEST_CMD:-"(none)"}
5. Commit your work with a descriptive message
6. When the goal is FULLY achieved, output exactly: LOOP_COMPLETE

${audit_section}

${audit_feedback_section}

${rejection_notice_section}

${stuckness_section}

## Rules
- Focus on ONE task per iteration — do it well
- Always commit with descriptive messages
- If tests fail, fix them before ending
- If stuck on the same issue for 2+ iterations, try a different approach
- Do NOT output LOOP_COMPLETE unless the goal is genuinely achieved
PROMPT
}

# ─── Stuckness Detection ─────────────────────────────────────────────────────
# Compares last 3 iteration log outputs for high overlap (>90% similar lines).
detect_stuckness() {
    if [[ "$ITERATION" -lt 3 ]]; then
        return 0
    fi

    local log1="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
    local log2="$LOG_DIR/iteration-$(( ITERATION - 2 )).log"
    local log3="$LOG_DIR/iteration-$(( ITERATION - 3 )).log"

    # Need at least 2 previous logs
    if [[ ! -f "$log1" || ! -f "$log2" ]]; then
        return 0
    fi

    # Compare last 50 lines of each (ignoring timestamps and blank lines)
    local lines1 lines2 common total overlap_pct
    lines1=$(tail -50 "$log1" 2>/dev/null | grep -v '^$' | sort || true)
    lines2=$(tail -50 "$log2" 2>/dev/null | grep -v '^$' | sort || true)

    if [[ -z "$lines1" || -z "$lines2" ]]; then
        return 0
    fi

    total=$(echo "$lines1" | wc -l | tr -d ' ')
    common=$(comm -12 <(echo "$lines1") <(echo "$lines2") 2>/dev/null | wc -l | tr -d ' ' || echo "0")

    if [[ "$total" -gt 0 ]]; then
        overlap_pct=$(( common * 100 / total ))
    else
        overlap_pct=0
    fi

    if [[ "$overlap_pct" -ge 90 ]]; then
        local diff_summary=""
        if [[ -f "$log3" ]]; then
            diff_summary=$(diff <(tail -30 "$log3" 2>/dev/null) <(tail -30 "$log1" 2>/dev/null) 2>/dev/null | head -10 || true)
        fi

        # Gather memory-based alternative approaches
        local alternatives=""
        if type memory_inject_context &>/dev/null 2>&1; then
            alternatives=$(memory_inject_context "build" 2>/dev/null | grep -i "fix:" | head -3 || true)
        fi

        cat <<STUCK_SECTION
## Stuckness Detected
Your last ${CONSECUTIVE_FAILURES:-2}+ iterations produced very similar output (${overlap_pct}% overlap).
You appear to be stuck on the same approach.

${diff_summary:+Changes between recent iterations:
$diff_summary
}
${alternatives:+Consider these alternative approaches from past fixes:
$alternatives
}
Try a fundamentally different approach:
- Break the problem into smaller steps
- Look for an entirely different implementation strategy
- Check if there's a dependency or configuration issue blocking progress
- Read error messages more carefully — the root cause may differ from your assumption
STUCK_SECTION
    fi
}

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
            if [[ -f "$recruit_roles_db" ]] && command -v jq &>/dev/null; then
                local recruit_desc
                recruit_desc=$(jq -r --arg r "$role" '.[$r].description // ""' "$recruit_roles_db" 2>/dev/null) || true
                if [[ -n "$recruit_desc" && "$recruit_desc" != "null" ]]; then
                    role_desc="$recruit_desc"
                fi
            fi
            # Fallback to hardcoded descriptions
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

build_claude_flags() {
    local flags=()
    flags+=("--model" "$MODEL")
    flags+=("--output-format" "json")

    if $SKIP_PERMISSIONS; then
        flags+=("--dangerously-skip-permissions")
    fi

    if [[ -n "$MAX_TURNS" ]]; then
        flags+=("--max-turns" "$MAX_TURNS")
    fi

    echo "${flags[*]}"
}

run_claude_iteration() {
    local log_file="$LOG_DIR/iteration-${ITERATION}.log"
    local json_file="$LOG_DIR/iteration-${ITERATION}.json"
    local prompt
    prompt="$(compose_prompt)"

    local flags
    flags="$(build_claude_flags)"

    local iter_start
    iter_start="$(now_epoch)"

    echo -e "\n${CYAN}${BOLD}▸${RESET} ${BOLD}Iteration ${ITERATION}/${MAX_ITERATIONS}${RESET} — Starting..."

    # Run Claude headless (with timeout + PID capture for signal handling)
    # Output goes to .json first, then we extract text into .log for compat
    local exit_code=0
    # shellcheck disable=SC2086
    local err_file="${json_file%.json}.stderr"
    if [[ -n "$TIMEOUT_CMD" ]]; then
        $TIMEOUT_CMD "$CLAUDE_TIMEOUT" claude -p "$prompt" $flags > "$json_file" 2>"$err_file" &
    else
        claude -p "$prompt" $flags > "$json_file" 2>"$err_file" &
    fi
    CHILD_PID=$!
    wait "$CHILD_PID" 2>/dev/null || exit_code=$?
    CHILD_PID=""
    if [[ "$exit_code" -eq 124 ]]; then
        warn "Claude CLI timed out after ${CLAUDE_TIMEOUT}s"
    fi

    # Extract text result from JSON into .log for backwards compatibility
    # With --output-format json, stdout is a JSON array; .[-1].result has the text
    _extract_text_from_json "$json_file" "$log_file" "$err_file"

    local iter_end
    iter_end="$(now_epoch)"
    local iter_duration=$(( iter_end - iter_start ))

    echo -e "  ${GREEN}✓${RESET} Claude session completed ($(format_duration "$iter_duration"), exit $exit_code)"

    # Accumulate token usage from this iteration's JSON output
    accumulate_loop_tokens "$json_file"

    # Show verbose output if requested
    if $VERBOSE; then
        echo -e "  ${DIM}─── Claude Output ───${RESET}"
        sed 's/^/  /' "$log_file" | head -100
        echo -e "  ${DIM}─────────────────────${RESET}"
    fi

    return $exit_code
}

# ─── Iteration Summary Extraction ────────────────────────────────────────────

extract_summary() {
    local log_file="$1"
    # Grab last meaningful lines from Claude output, skipping empty lines
    local summary
    summary="$(grep -v '^$' "$log_file" | tail -5 | head -3 2>/dev/null || echo "(no output)")"
    # Truncate long lines
    summary="$(echo "$summary" | cut -c1-120)"

    # Sanitize: if summary is just a CLI/API error, replace with generic text
    if echo "$summary" | grep -qiE 'Invalid API key|authentication_error|rate_limit|API key expired|ANTHROPIC_API_KEY'; then
        summary="(CLI error — no useful output this iteration)"
    fi

    echo "$summary"
}

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
        complete)        status_display="${GREEN}✓ Complete (LOOP_COMPLETE detected)${RESET}" ;;
        circuit_breaker) status_display="${RED}✗ Circuit breaker tripped${RESET}" ;;
        max_iterations)  status_display="${YELLOW}⚠ Max iterations reached${RESET}" ;;
        interrupted)     status_display="${YELLOW}⚠ Interrupted by user${RESET}" ;;
        error)           status_display="${RED}✗ Error${RESET}" ;;
        *)               status_display="${DIM}$STATUS${RESET}" ;;
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
        if ! git -C "$PROJECT_ROOT" rev-parse --verify "$branch_name" &>/dev/null; then
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

cd "$WORK_DIR"
ITERATION=0
CONSECUTIVE_FAILURES=0

echo -e "${CYAN}${BOLD}▸${RESET} Agent ${AGENT_NUM}/${TOTAL_AGENTS} starting in ${WORK_DIR}"

while [[ "$ITERATION" -lt "$MAX_ITERATIONS" ]]; do
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

    # Auto-commit
    git add -A 2>/dev/null || true
    if git commit -m "agent-${AGENT_NUM}: iteration ${ITERATION}" --no-verify 2>/dev/null; then
        git push origin "loop/agent-${AGENT_NUM}" 2>/dev/null || true
        echo -e "  ${GREEN}✓${RESET} Committed and pushed"
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
        echo -e "  ${RED}✗${RESET} Circuit breaker — stopping agent ${AGENT_NUM}"
        break
    fi

    sleep 2
done

echo -e "\n${DIM}Agent ${AGENT_NUM} finished after ${ITERATION} iterations${RESET}"
WORKEREOF

    # Replace placeholders — use awk for all values to avoid sed injection
    # (sed breaks on & | \ in paths and test commands)
    sed_i "s|__AGENT_NUM__|${agent_num}|g" "$worker_script"
    sed_i "s|__TOTAL_AGENTS__|${total_agents}|g" "$worker_script"
    sed_i "s|__MAX_ITERATIONS__|${MAX_ITERATIONS}|g" "$worker_script"
    # Paths and commands may contain sed-special chars — use awk
    awk -v val="$wt_path" '{gsub(/__WORK_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
        && mv "${worker_script}.tmp" "$worker_script"
    awk -v val="$LOG_DIR" '{gsub(/__LOG_DIR__/, val); print}' "$worker_script" > "${worker_script}.tmp" \
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

        tmux split-window -t "$MULTI_WINDOW_NAME" -c "$PROJECT_ROOT"
        sleep 0.1
        tmux send-keys -t "$MULTI_WINDOW_NAME" "printf '\\033]2;agent-${i}\\033\\\\'" Enter
        sleep 0.1
        tmux send-keys -t "$MULTI_WINDOW_NAME" "bash '$worker_script'" Enter
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
                age=$(( $(now_epoch) - $(stat -f %m "$latest_log" 2>/dev/null || echo 0) ))
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

        sleep 5
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
    if [[ "$SESSION_RESTART" == "true" ]]; then
        # Restart: state already reset by run_loop_with_restarts, skip init
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — fresh context, reading progress"
    elif $RESUME; then
        resume_state
    else
        initialize_state
    fi

    # Apply adaptive budget/model before showing banner
    apply_adaptive_budget
    MODEL="$(select_adaptive_model "build" "$MODEL")"

    # Track applied memory fix patterns for outcome recording
    _applied_fix_pattern=""

    show_banner

    while true; do
        # Pre-checks (before incrementing — ITERATION tracks completed count)
        check_circuit_breaker || break
        check_max_iterations || break
        ITERATION=$(( ITERATION + 1 ))

        # Try memory-based fix suggestion on retry after test failure
        if [[ "${TEST_PASSED:-}" == "false" ]]; then
            local _last_error=""
            local _prev_log="$LOG_DIR/iteration-$(( ITERATION - 1 )).log"
            if [[ -f "$_prev_log" ]]; then
                _last_error=$(tail -20 "$_prev_log" 2>/dev/null | grep -iE '(error|fail|exception)' | head -1 || true)
            fi
            local _fix_suggestion=""
            if type memory_closed_loop_inject &>/dev/null 2>&1 && [[ -n "${_last_error:-}" ]]; then
                _fix_suggestion=$(memory_closed_loop_inject "$_last_error" 2>/dev/null) || true
            fi
            if [[ -n "${_fix_suggestion:-}" ]]; then
                _applied_fix_pattern="${_last_error}"
                GOAL="KNOWN FIX (from past success): ${_fix_suggestion}

${GOAL}"
                info "Memory fix injected: ${_fix_suggestion:0:80}"
            fi
        fi

        # Run Claude
        local exit_code=0
        run_claude_iteration || exit_code=$?

        local log_file="$LOG_DIR/iteration-${ITERATION}.log"

        # Detect fatal CLI errors (API key, auth, network) — abort immediately
        if check_fatal_error "$log_file" "$exit_code"; then
            STATUS="error"
            write_state
            write_progress
            error "Fatal CLI error detected — aborting loop (see iteration log)"
            show_summary
            return 1
        fi

        # Mid-loop memory refresh — re-query with current error context after iteration 3
        if [[ "$ITERATION" -ge 3 ]] && type memory_inject_context &>/dev/null 2>&1; then
            local refresh_ctx
            refresh_ctx=$(tail -20 "$log_file" 2>/dev/null || true)
            if [[ -n "$refresh_ctx" ]]; then
                local refreshed_memory
                refreshed_memory=$(memory_inject_context "build" "$refresh_ctx" 2>/dev/null | head -5 || true)
                if [[ -n "$refreshed_memory" ]]; then
                    # Append to next iteration's memory context
                    local memory_refresh_file="$LOG_DIR/memory-refresh-${ITERATION}.txt"
                    echo "$refreshed_memory" > "$memory_refresh_file"
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

        # Track fix outcome for memory effectiveness
        if [[ -n "${_applied_fix_pattern:-}" ]]; then
            if type memory_record_fix_outcome &>/dev/null 2>&1; then
                if [[ "${TEST_PASSED:-}" == "true" ]]; then
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "true" 2>/dev/null || true
                else
                    memory_record_fix_outcome "$_applied_fix_pattern" "true" "false" 2>/dev/null || true
                fi
            fi
            _applied_fix_pattern=""
        fi

        # Audit agent (reviews implementer's work)
        run_audit_agent

        # Quality gates (automated checks)
        run_quality_gates

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

        sleep 2
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
        if [[ "$MAX_RESTARTS" -le 0 ]]; then
            return "$loop_exit"
        fi
        if [[ "$RESTART_COUNT" -ge "$MAX_RESTARTS" ]]; then
            warn "Max restarts ($MAX_RESTARTS) reached — stopping"
            return "$loop_exit"
        fi
        # Hard cap safety net
        if [[ "$RESTART_COUNT" -ge 5 ]]; then
            warn "Hard restart cap (5) reached — stopping"
            return "$loop_exit"
        fi

        # Check if tests are still failing (worth restarting)
        if [[ "${TEST_PASSED:-}" == "true" ]]; then
            info "Tests passing but loop incomplete — restarting session"
        else
            info "Tests failing and loop exhausted — restarting with fresh context"
        fi

        RESTART_COUNT=$(( RESTART_COUNT + 1 ))
        if type emit_event &>/dev/null 2>&1; then
            emit_event "loop.restart" "restart=$RESTART_COUNT" "max=$MAX_RESTARTS" "iteration=$ITERATION"
        fi
        info "Session restart ${RESTART_COUNT}/${MAX_RESTARTS} — resetting iteration counter"

        # Reset ALL iteration-level state for the new session
        # SESSION_RESTART tells run_single_agent_loop to skip init/resume
        SESSION_RESTART=true
        ITERATION=0
        CONSECUTIVE_FAILURES=0
        EXTENSION_COUNT=0
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

        sleep 2
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
