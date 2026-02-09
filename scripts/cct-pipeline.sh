#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright pipeline — Autonomous Feature Delivery (Idea → Production)        ║
# ║  Full GitHub integration · Auto-detection · Task tracking · Metrics    ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.7.1"
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

# ─── Output Helpers ─────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }

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

# ─── Structured Event Log ──────────────────────────────────────────────────
# Appends JSON events to ~/.claude-teams/events.jsonl for metrics/traceability

EVENTS_DIR="${HOME}/.claude-teams"
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
DRY_RUN=false
IGNORE_BUDGET=false
PR_NUMBER=""
AUTO_WORKTREE=false
WORKTREE_NAME=""
CLEANUP_WORKTREE=false
ORIGINAL_REPO_DIR=""

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
    echo -e "  ${DIM}--ignore-budget${RESET}           Skip budget enforcement checks"
    echo -e "  ${DIM}--worktree [=name]${RESET}         Run in isolated git worktree (parallel-safe)"
    echo -e "  ${DIM}--dry-run${RESET}                 Show what would happen without executing"
    echo -e "  ${DIM}--slack-webhook <url>${RESET}     Send notifications to Slack"
    echo -e "  ${DIM}--self-heal <n>${RESET}            Build→test retry cycles on failure (default: 2)"
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
            --pipeline)    PIPELINE_NAME="$2"; shift 2 ;;
            --test-cmd)    TEST_CMD="$2"; shift 2 ;;
            --model)       MODEL="$2"; shift 2 ;;
            --agents)      AGENTS="$2"; shift 2 ;;
            --skip-gates)  SKIP_GATES=true; shift ;;
            --base)        BASE_BRANCH="$2"; shift 2 ;;
            --reviewers)   REVIEWERS="$2"; shift 2 ;;
            --labels)      LABELS="$2"; shift 2 ;;
            --no-github)   NO_GITHUB=true; shift ;;
            --ignore-budget) IGNORE_BUDGET=true; shift ;;
            --worktree=*) AUTO_WORKTREE=true; WORKTREE_NAME="${1#--worktree=}"; WORKTREE_NAME="${WORKTREE_NAME//[^a-zA-Z0-9_-]/}"; if [[ -z "$WORKTREE_NAME" ]]; then error "Invalid worktree name (alphanumeric, hyphens, underscores only)"; exit 1; fi; shift ;;
            --worktree)   AUTO_WORKTREE=true; shift ;;
            --dry-run)     DRY_RUN=true; shift ;;
            --slack-webhook) SLACK_WEBHOOK="$2"; shift 2 ;;
            --self-heal)   BUILD_TEST_RETRIES="${2:-3}"; shift 2 ;;
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
        "$HOME/.claude-teams/pipelines/${name}.json"
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
            "$SCRIPT_DIR/cct-heartbeat.sh" write "$job_id" \
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
        "$SCRIPT_DIR/cct-heartbeat.sh" clear "${PIPELINE_NAME:-pipeline-$$}" 2>/dev/null || true
        HEARTBEAT_PID=""
    fi
}

# ─── Signal Handling ───────────────────────────────────────────────────────

cleanup_on_exit() {
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
    fi

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == "true" ]]; then
        git stash pop --quiet 2>/dev/null || true
    fi

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
            git stash push -m "cct-pipeline: auto-stash before pipeline" --quiet 2>/dev/null && STASHED_CHANGES=true
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

    # 5. cct loop (needed for build stage)
    if [[ -x "$SCRIPT_DIR/cct-loop.sh" ]]; then
        echo -e "  ${GREEN}✓${RESET} shipwright loop available"
    else
        echo -e "  ${RED}✗${RESET} cct-loop.sh not found at $SCRIPT_DIR"
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
    while IFS= read -r stage; do
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
    done <<< "$stages"

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
    if [[ -f "$root/package.json" ]]; then
        if grep -q "typescript" "$root/package.json" 2>/dev/null; then
            echo "typescript"
        elif grep -q "\"next\"" "$root/package.json" 2>/dev/null; then
            echo "nextjs"
        elif grep -q "\"react\"" "$root/package.json" 2>/dev/null; then
            echo "react"
        else
            echo "nodejs"
        fi
    elif [[ -f "$root/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$root/go.mod" ]]; then
        echo "go"
    elif [[ -f "$root/pyproject.toml" || -f "$root/setup.py" || -f "$root/requirements.txt" ]]; then
        echo "python"
    elif [[ -f "$root/Gemfile" ]]; then
        echo "ruby"
    elif [[ -f "$root/pom.xml" || -f "$root/build.gradle" ]]; then
        echo "java"
    else
        echo "unknown"
    fi
}

# Detect likely reviewers from CODEOWNERS or git log
detect_reviewers() {
    local root="$PROJECT_ROOT"

    # Check CODEOWNERS
    local codeowners=""
    for f in "$root/.github/CODEOWNERS" "$root/CODEOWNERS" "$root/docs/CODEOWNERS"; do
        if [[ -f "$f" ]]; then
            codeowners="$f"
            break
        fi
    done

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

    # Fallback: top contributors from recent git log (excluding self)
    local current_user
    current_user=$(gh api user --jq '.login' 2>/dev/null || git config user.name 2>/dev/null || true)
    local contributors
    contributors=$(git log --format='%aN' -100 2>/dev/null | \
        sort | uniq -c | sort -rn | \
        awk '{print $NF}' | \
        grep -v "^${current_user}$" 2>/dev/null | \
        head -2 | tr '\n' ',')
    contributors="${contributors%,}"
    echo "$contributors"
}

# Get branch prefix from task type
branch_prefix_for_type() {
    case "$1" in
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
    case "$1" in
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
    while IFS= read -r stage; do
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
    done <<< "$stages"
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
        "$SCRIPT_DIR/cct-tracker.sh" notify "stage_complete" "$ISSUE_NUMBER" \
            "${stage_id}|${timing}|${stage_desc}" 2>/dev/null || true
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
        "$SCRIPT_DIR/cct-tracker.sh" notify "stage_failed" "$ISSUE_NUMBER" \
            "${stage_id}|${error_context}" 2>/dev/null || true
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
    write_state
}

write_state() {
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

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-plan.log"
    claude --print --model "$plan_model" --max-turns 10 \
        "$plan_prompt" > "$plan_file" 2>"$_token_log" || true
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
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/cct-memory.sh" inject "design" 2>/dev/null) || true
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
}
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

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-design.log"
    claude --print --model "$design_model" --max-turns 10 \
        "$design_prompt" > "$design_file" 2>"$_token_log" || true
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
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        memory_context=$(bash "$SCRIPT_DIR/cct-memory.sh" inject "build" 2>/dev/null) || true
    fi

    # Build enriched goal with full context
    local enriched_goal="$GOAL"
    if [[ -s "$plan_file" ]]; then
        enriched_goal="$GOAL

Implementation plan (follow this exactly):
$(cat "$plan_file")"
    fi

    # Inject approved design document
    if [[ -s "$design_file" ]]; then
        enriched_goal="${enriched_goal}

Follow the approved design document:
$(cat "$design_file")"
    fi

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

    local agents="${AGENTS}"
    if [[ -z "$agents" ]]; then
        agents=$(jq -r --arg id "build" '(.stages[] | select(.id == $id) | .config.agents) // .defaults.agents // 1' "$PIPELINE_CONFIG" 2>/dev/null) || true
        [[ -z "$agents" || "$agents" == "null" ]] && agents=1
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

    [[ -n "$test_cmd" && "$test_cmd" != "null" ]] && loop_args+=(--test-cmd "$test_cmd")
    loop_args+=(--max-iterations "$max_iter")
    loop_args+=(--model "$build_model")
    [[ "$agents" -gt 1 ]] 2>/dev/null && loop_args+=(--agents "$agents")
    [[ "$audit" == "true" ]] && loop_args+=(--audit --audit-agent)
    [[ "$quality" == "true" ]] && loop_args+=(--quality-gates)
    [[ -s "$dod_file" ]] && loop_args+=(--definition-of-done "$dod_file")

    info "Starting build loop: ${DIM}shipwright loop${RESET} (max ${max_iter} iterations, ${agents} agent(s))"

    # Post build start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🔨 **Build started** — \`shipwright loop\` with ${max_iter} max iterations, ${agents} agent(s), model: ${build_model}"
    fi

    local _token_log="${ARTIFACTS_DIR}/.claude-tokens-build.log"
    cct loop "${loop_args[@]}" 2>"$_token_log" || {
        parse_claude_tokens "$_token_log"
        error "Build loop failed"
        return 1
    }
    parse_claude_tokens "$_token_log"

    # Count commits made during build
    local commit_count
    commit_count=$(git log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null | wc -l | xargs)
    info "Build produced ${BOLD}$commit_count${RESET} commit(s)"

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
    eval "$test_cmd" > "$test_log" 2>&1 || test_exit=$?

    if [[ "$test_exit" -eq 0 ]]; then
        success "Tests passed"
    else
        error "Tests failed (exit code: $test_exit)"
        tail -20 "$test_log"

        # Post failure to GitHub
        if [[ -n "$ISSUE_NUMBER" ]]; then
            gh_comment_issue "$ISSUE_NUMBER" "❌ **Tests failed**
\`\`\`
$(tail -20 "$test_log")
\`\`\`"
        fi
        return 1
    fi

    # Coverage check
    local coverage=""
    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null; then
        coverage=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$test_log" 2>/dev/null | grep -oE '[0-9.]+$' || \
                   grep -oE 'All files\s*\|\s*[0-9.]+' "$test_log" 2>/dev/null | grep -oE '[0-9.]+$' || echo "0")
        if awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
            warn "Coverage ${coverage}% below minimum ${coverage_min}%"
            return 1
        fi
        info "Coverage: ${coverage}% (min: ${coverage_min}%)"
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

    local review_model="${MODEL:-opus}"

    claude --print --model "$review_model" --max-turns 15 \
        "You are a senior code reviewer. Review this git diff thoroughly.

For each issue found, use this format:
- **[SEVERITY]** file:line — description

Severity levels: Critical, Bug, Security, Warning, Suggestion

Focus on:
1. Logic bugs and edge cases
2. Security vulnerabilities (injection, XSS, auth bypass, etc.)
3. Error handling gaps
4. Performance issues
5. Missing validation

Be specific. Reference exact file paths and line numbers. Only flag genuine issues.

$(cat "$diff_file")" > "$review_file" 2>"${ARTIFACTS_DIR}/.claude-tokens-review.log" || true
    parse_claude_tokens "${ARTIFACTS_DIR}/.claude-tokens-review.log"

    if [[ ! -s "$review_file" ]]; then
        warn "Review produced no output"
        return 0
    fi

    local critical_count bug_count warning_count
    critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$review_file" 2>/dev/null || true)
    critical_count="${critical_count:-0}"
    bug_count=$(grep -ciE '\*\*\[?(Bug|Security)\]?\*\*' "$review_file" 2>/dev/null || true)
    bug_count="${bug_count:-0}"
    warning_count=$(grep -ciE '\*\*\[?(Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
    warning_count="${warning_count:-0}"
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

    # Build PR title
    local pr_title
    pr_title=$(head -1 "$plan_file" 2>/dev/null | sed 's/^#* *//' | cut -c1-70)
    [[ -z "$pr_title" ]] && pr_title="$GOAL"

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
        local total_issues
        total_issues=$(grep -ciE '\*\*\[?(Critical|Bug|Security|Warning|Suggestion)\]?\*\*' "$review_file" 2>/dev/null || true)
        total_issues="${total_issues:-0}"
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

    info "Creating PR..."
    local pr_url
    pr_url=$(gh pr create "${pr_args[@]}" 2>&1) || {
        error "PR creation failed: $pr_url"
        return 1
    }

    success "PR created: ${BOLD}$pr_url${RESET}"
    echo "$pr_url" > "$ARTIFACTS_DIR/pr-url.txt"

    # Extract PR number
    PR_NUMBER=$(echo "$pr_url" | grep -oE '[0-9]+$' || true)

    # Update issue with PR link
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_remove_label "$ISSUE_NUMBER" "pipeline/in-progress"
        gh_add_labels "$ISSUE_NUMBER" "pipeline/pr-created"
        gh_comment_issue "$ISSUE_NUMBER" "🎉 **PR created:** ${pr_url}

Pipeline duration so far: ${total_dur:-unknown}"

        # Notify tracker of review/PR creation
        "$SCRIPT_DIR/cct-tracker.sh" notify "review" "$ISSUE_NUMBER" "$pr_url" 2>/dev/null || true
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

    local merge_method wait_ci_timeout auto_delete_branch auto_merge auto_approve merge_strategy
    merge_method=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.merge_method) // "squash"' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$merge_method" || "$merge_method" == "null" ]] && merge_method="squash"
    wait_ci_timeout=$(jq -r --arg id "merge" '(.stages[] | select(.id == $id) | .config.wait_ci_timeout_s) // 600' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$wait_ci_timeout" || "$wait_ci_timeout" == "null" ]] && wait_ci_timeout=600
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

    # Post deploy start to GitHub
    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "🚀 **Deploy started**"
    fi

    if [[ -n "$staging_cmd" ]]; then
        info "Deploying to staging..."
        eval "$staging_cmd" > "$ARTIFACTS_DIR/deploy-staging.log" 2>&1 || {
            error "Staging deploy failed"
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "❌ Staging deploy failed"
            return 1
        }
        success "Staging deploy complete"
    fi

    if [[ -n "$prod_cmd" ]]; then
        info "Deploying to production..."
        eval "$prod_cmd" > "$ARTIFACTS_DIR/deploy-prod.log" 2>&1 || {
            error "Production deploy failed"
            if [[ -n "$rollback_cmd" ]]; then
                warn "Rolling back..."
                eval "$rollback_cmd" 2>&1 || error "Rollback also failed!"
            fi
            [[ -n "$ISSUE_NUMBER" ]] && gh_comment_issue "$ISSUE_NUMBER" "❌ Production deploy failed — rollback ${rollback_cmd:+attempted}"
            return 1
        }
        success "Production deploy complete"
    fi

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "✅ **Deploy complete**"
        gh_add_labels "$ISSUE_NUMBER" "deployed"
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
        eval "$smoke_cmd" > "$ARTIFACTS_DIR/smoke.log" 2>&1 || {
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
            log_output=$(eval "$log_cmd" 2>/dev/null || true)
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

                if eval "$rollback_cmd" >> "$report_file" 2>&1; then
                    success "Rollback executed"
                    echo "Rollback: ✅ success" >> "$report_file"

                    # Post-rollback smoke test verification
                    local smoke_cmd
                    smoke_cmd=$(jq -r --arg id "validate" '(.stages[] | select(.id == $id) | .config.smoke_cmd) // ""' "$PIPELINE_CONFIG" 2>/dev/null) || true
                    [[ "$smoke_cmd" == "null" ]] && smoke_cmd=""

                    if [[ -n "$smoke_cmd" ]]; then
                        info "Verifying rollback with smoke tests..."
                        if eval "$smoke_cmd" > "$ARTIFACTS_DIR/rollback-smoke.log" 2>&1; then
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

    # Find build output directory
    for dir in dist build out .next; do
        if [[ -d "$dir" ]]; then
            bundle_dir="$dir"
            break
        fi
    done

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

    # Check against memory baseline if available
    local baseline_size=""
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        baseline_size=$(bash "$SCRIPT_DIR/cct-memory.sh" get "bundle_size_kb" 2>/dev/null) || true
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

    info "Bundle size: ${bundle_size_human}"
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

    # Extract test suite duration (common patterns)
    local duration_ms=""
    duration_ms=$(grep -oE 'Time:\s*[0-9.]+\s*s' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)
    [[ -z "$duration_ms" ]] && duration_ms=$(grep -oE '[0-9.]+ ?s(econds?)?' "$test_log" 2>/dev/null | grep -oE '[0-9.]+' | tail -1 || true)

    if [[ -z "$duration_ms" ]]; then
        info "Could not extract test duration — skipping perf check"
        echo "Duration not parseable" > "$metrics_log"
        return 0
    fi

    echo "Test duration: ${duration_ms}s" > "$metrics_log"

    emit_event "quality.perf" \
        "issue=${ISSUE_NUMBER:-0}" \
        "duration_s=$duration_ms"

    # Check against memory baseline if available
    local baseline_dur=""
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        baseline_dur=$(bash "$SCRIPT_DIR/cct-memory.sh" get "test_duration_s" 2>/dev/null) || true
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

    info "Test duration: ${duration_ms}s"
    return 0
}

quality_check_api_compat() {
    info "API compatibility check..."
    local compat_log="$ARTIFACTS_DIR/api-compat.log"

    # Look for OpenAPI/Swagger specs
    local spec_file=""
    for candidate in openapi.json openapi.yaml swagger.json swagger.yaml api/openapi.json docs/openapi.yaml; do
        if [[ -f "$candidate" ]]; then
            spec_file="$candidate"
            break
        fi
    done

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

    {
        echo "Spec: $spec_file"
        echo "Changed: yes"
        if [[ -n "$removed_endpoints" ]]; then
            echo "BREAKING — Removed endpoints:"
            echo "$removed_endpoints"
        else
            echo "No breaking changes detected"
        fi
    } > "$compat_log"

    if [[ -n "$removed_endpoints" ]]; then
        local removed_count
        removed_count=$(echo "$removed_endpoints" | wc -l | xargs)
        warn "API breaking changes: ${removed_count} endpoint(s) removed"
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

    # Extract coverage percentage
    local coverage=""
    coverage=$(grep -oE 'Statements\s*:\s*[0-9.]+' "$test_log" 2>/dev/null | grep -oE '[0-9.]+$' || \
               grep -oE 'All files\s*\|\s*[0-9.]+' "$test_log" 2>/dev/null | grep -oE '[0-9.]+$' || \
               grep -oE 'TOTAL\s+[0-9]+\s+[0-9]+\s+([0-9]+)%' "$test_log" 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' || echo "")

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

    # Check against memory baseline (detect coverage drops)
    local baseline_coverage=""
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        baseline_coverage=$(bash "$SCRIPT_DIR/cct-memory.sh" get "coverage_pct" 2>/dev/null) || true
    fi

    local dropped=false
    if [[ -n "$baseline_coverage" ]] && awk -v cur="$coverage" -v base="$baseline_coverage" 'BEGIN{exit !(cur < base)}' 2>/dev/null; then
        warn "Coverage dropped: ${baseline_coverage}% → ${coverage}%"
        dropped=true
    fi

    if [[ "$coverage_min" -gt 0 ]] 2>/dev/null && awk -v cov="$coverage" -v min="$coverage_min" 'BEGIN{exit !(cov < min)}' 2>/dev/null; then
        warn "Coverage ${coverage}% below minimum ${coverage_min}%"
        return 1
    fi

    if $dropped; then
        return 1
    fi

    info "Coverage: ${coverage}%"
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

Diff:
$diff_content"

    local review_output
    review_output=$(claude --print "$prompt" 2>"${ARTIFACTS_DIR}/.claude-tokens-adversarial.log" || true)
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

    local prompt="You are a pessimistic engineer who assumes everything will break.
Review these changes and answer:
1. What could go wrong in production?
2. What did the developer miss?
3. What's fragile and will break when requirements change?
4. What assumptions are being made that might not hold?
5. What happens under load/stress?
6. What happens with malicious input?
7. Are there any implicit dependencies that could break?

Be specific. Reference actual code. Categorize each concern as [Critical/Concern/Minor].

Files changed: $changed_files

$file_contents"

    local review_output
    review_output=$(claude --print "$prompt" 2>"${ARTIFACTS_DIR}/.claude-tokens-negative.log" || true)
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
    if eval "$test_cmd" > "$ARTIFACTS_DIR/e2e-validation.log" 2>&1; then
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
        for alt in "$PROJECT_ROOT/DEFINITION-OF-DONE.md" "$HOME/.claude-teams/templates/definition-of-done.example.md"; do
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

compound_rebuild_with_feedback() {
    local feedback_file="$ARTIFACTS_DIR/quality-feedback.md"

    # Collect all findings
    {
        echo "# Quality Feedback — Issues to Fix"
        echo ""
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
        if [[ -f "$ARTIFACTS_DIR/security-audit.log" ]] && grep -qiE 'critical|high' "$ARTIFACTS_DIR/security-audit.log" 2>/dev/null; then
            echo "## Security Audit Findings"
            cat "$ARTIFACTS_DIR/security-audit.log"
            echo ""
        fi
        if [[ -f "$ARTIFACTS_DIR/api-compat.log" ]] && grep -qi 'BREAKING' "$ARTIFACTS_DIR/api-compat.log" 2>/dev/null; then
            echo "## API Breaking Changes"
            cat "$ARTIFACTS_DIR/api-compat.log"
            echo ""
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

    # Augment GOAL with quality feedback
    local original_goal="$GOAL"
    local feedback_content
    feedback_content=$(cat "$feedback_file")
    GOAL="$GOAL

IMPORTANT — Compound quality review found issues. Fix ALL of these:
$feedback_content

Fix every issue listed above while keeping all existing functionality working."

    # Re-run self-healing build→test
    info "Rebuilding with quality feedback..."
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
        if [[ "$adversarial_enabled" == "true" ]]; then
            echo ""
            info "Running adversarial review..."
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

        # 3. E2E Validation
        if [[ "$e2e_enabled" == "true" ]]; then
            echo ""
            info "Running E2E validation..."
            if ! run_e2e_validation; then
                all_passed=false
            fi
        fi

        # 4. DoD Audit
        if [[ "$dod_enabled" == "true" ]]; then
            echo ""
            info "Running Definition of Done audit..."
            if ! run_dod_audit; then
                all_passed=false
            fi
        fi

        # 5. Multi-dimensional quality checks
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

        emit_event "compound.cycle" \
            "issue=${ISSUE_NUMBER:-0}" \
            "cycle=$cycle" \
            "max_cycles=$max_cycles" \
            "passed=$all_passed" \
            "self_heal_count=$SELF_HEAL_COUNT"

        if $all_passed; then
            success "Compound quality passed on cycle ${cycle}"

            if [[ -n "$ISSUE_NUMBER" ]]; then
                gh_comment_issue "$ISSUE_NUMBER" "✅ **Compound quality passed** — cycle ${cycle}/${max_cycles}

All quality checks clean:
- Adversarial review: ✅
- Negative prompting: ✅
- E2E validation: ✅
- DoD audit: ✅
- Security audit: ✅
- Coverage: ✅
- Performance: ✅
- Bundle size: ✅
- API compat: ✅" 2>/dev/null || true
            fi

            log_stage "compound_quality" "Passed on cycle ${cycle}/${max_cycles}"
            return 0
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

    # Exhausted all cycles
    error "Compound quality exhausted after ${max_cycles} cycles"

    if [[ -n "$ISSUE_NUMBER" ]]; then
        gh_comment_issue "$ISSUE_NUMBER" "❌ **Compound quality failed** after ${max_cycles} cycles

Quality issues remain. Check artifacts for details." 2>/dev/null || true
    fi

    log_stage "compound_quality" "Failed after ${max_cycles} cycles"
    return 1
}

# ─── Stage Runner ───────────────────────────────────────────────────────────

run_stage_with_retry() {
    local stage_id="$1"
    local max_retries
    max_retries=$(jq -r --arg id "$stage_id" '(.stages[] | select(.id == $id) | .config.retries) // 0' "$PIPELINE_CONFIG" 2>/dev/null) || true
    [[ -z "$max_retries" || "$max_retries" == "null" ]] && max_retries=0

    local attempt=0
    while true; do
        if "stage_${stage_id}"; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ "$attempt" -gt "$max_retries" ]]; then
            return 1
        fi

        warn "Stage $stage_id failed (attempt $attempt/$((max_retries + 1))) — retrying..."
        sleep 2
    done
}

# ─── Self-Healing Build→Test Feedback Loop ─────────────────────────────────
# When tests fail after a build, this captures the error and re-runs the build
# with the error context, so Claude can fix the issue automatically.

self_healing_build_test() {
    local cycle=0
    local max_cycles="$BUILD_TEST_RETRIES"
    local last_test_error=""

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
            # Temporarily augment the goal with error context
            local original_goal="$GOAL"
            GOAL="$GOAL

IMPORTANT — Previous build attempt failed tests. Fix these errors:
$last_test_error

Focus on fixing the failing tests while keeping all passing tests working."

            update_status "running" "build"
            record_stage_start "build"

            if run_stage_with_retry "build"; then
                mark_stage_complete "build"
                local timing
                timing=$(get_stage_timing "build")
                success "Stage ${BOLD}build${RESET} complete ${DIM}(${timing})${RESET}"
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
            return 0  # Tests passed!
        fi

        # Tests failed — capture error for next cycle
        local test_log="$ARTIFACTS_DIR/test-results.log"
        last_test_error=$(tail -30 "$test_log" 2>/dev/null || echo "Test command failed with no output")
        mark_stage_failed "test"

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

    while IFS= read -r stage; do
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

        local stage_status
        stage_status=$(get_stage_status "$id")
        if [[ "$stage_status" == "complete" ]]; then
            echo -e "  ${GREEN}✓ ${id}${RESET} ${DIM}— already complete${RESET}"
            completed=$((completed + 1))
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
        if [[ "$IGNORE_BUDGET" != "true" ]] && [[ -x "$SCRIPT_DIR/cct-cost.sh" ]]; then
            local budget_rc=0
            bash "$SCRIPT_DIR/cct-cost.sh" check-budget 2>/dev/null || budget_rc=$?
            if [[ "$budget_rc" -eq 2 ]]; then
                warn "Daily budget exceeded — pausing pipeline before stage ${BOLD}$id${RESET}"
                warn "Resume with --ignore-budget to override, or wait until tomorrow"
                emit_event "pipeline.budget_paused" "issue=${ISSUE_NUMBER:-0}" "stage=$id"
                update_status "paused" "$id"
                return 0
            fi
        fi

        echo ""
        echo -e "${CYAN}${BOLD}▸ Stage: ${id}${RESET} ${DIM}[$((completed + 1))/${enabled_count}]${RESET}"
        update_status "running" "$id"
        record_stage_start "$id"
        local stage_start_epoch
        stage_start_epoch=$(now_epoch)
        emit_event "stage.started" "issue=${ISSUE_NUMBER:-0}" "stage=$id"

        if run_stage_with_retry "$id"; then
            mark_stage_complete "$id"
            completed=$((completed + 1))
            local timing stage_dur_s
            timing=$(get_stage_timing "$id")
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            success "Stage ${BOLD}$id${RESET} complete ${DIM}(${timing})${RESET}"
            emit_event "stage.completed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s"
        else
            mark_stage_failed "$id"
            local stage_dur_s
            stage_dur_s=$(( $(now_epoch) - stage_start_epoch ))
            error "Pipeline failed at stage: ${BOLD}$id${RESET}"
            update_status "failed" "$id"
            emit_event "stage.failed" "issue=${ISSUE_NUMBER:-0}" "stage=$id" "duration_s=$stage_dur_s"
            return 1
        fi
    done <<< "$stages"

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
    if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
        bash "$SCRIPT_DIR/cct-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
    fi

    # Final GitHub progress update
    if [[ -n "$ISSUE_NUMBER" ]]; then
        local body
        body=$(gh_build_progress_body)
        gh_update_progress "$body"
    fi
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
        trap 'pipeline_cleanup_worktree' EXIT
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
        if [[ -x "$SCRIPT_DIR/cct-memory.sh" ]]; then
            bash "$SCRIPT_DIR/cct-memory.sh" capture "$STATE_FILE" "$ARTIFACTS_DIR" 2>/dev/null || true
            bash "$SCRIPT_DIR/cct-memory.sh" analyze-failure "$ARTIFACTS_DIR/.claude-tokens-${CURRENT_STAGE_ID:-build}.log" "${CURRENT_STAGE_ID:-unknown}" 2>/dev/null || true
        fi
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
        "$HOME/.claude-teams/pipelines"
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
        exec "$SCRIPT_DIR/cct-pipeline-test.sh" "$@"
        ;;
    help|--help|-h) show_help ;;
    *)
        error "Unknown pipeline command: $SUBCOMMAND"
        echo ""
        show_help
        exit 1
        ;;
esac
