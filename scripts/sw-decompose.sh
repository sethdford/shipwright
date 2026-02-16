#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright decompose — Intelligent Issue Decomposition                  ║
# ║  Analyze complexity · Auto-create subtasks · Track progress             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="2.1.0"
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

# ─── Configuration ─────────────────────────────────────────────────────────
COMPLEXITY_THRESHOLD=70          # Decompose if complexity > this
HOURS_THRESHOLD=8                # Decompose if estimated hours > this
MAX_SUBTASKS=5
MIN_SUBTASKS=3
DECOMPOSE_LABEL="subtask"
DECOMPOSED_MARKER_LABEL="decomposed"

# ─── Helper: Check if issue has label ──────────────────────────────────────
_has_label() {
    local issue_num="$1"
    local label="$2"

    if [[ "$NO_GITHUB" == "true" ]]; then
        return 1
    fi

    local labels
    labels=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' 2>/dev/null || echo "")
    [[ "$labels" =~ $label ]]
}

# ─── Helper: Call Claude for complexity analysis ──────────────────────────
_decompose_call_claude() {
    local prompt="$1"

    # Verify claude CLI is available
    if ! command -v claude >/dev/null 2>&1; then
        error "claude CLI not found"
        echo '{"error":"claude_cli_not_found"}'
        return 1
    fi

    # Call Claude (--print mode returns raw text response, max-turns 1)
    local response
    if ! response=$(claude --print --max-turns 1 "$prompt" 2>/dev/null); then
        error "Claude call failed"
        echo '{"error":"claude_call_failed"}'
        return 1
    fi

    # Extract JSON from the response
    local result
    result=$(echo "$response" | jq -c . 2>/dev/null || echo "")

    if [[ -z "$result" || "$result" == "null" ]]; then
        error "Failed to parse Claude response as JSON"
        echo '{"error":"parse_failed"}'
        return 1
    fi

    echo "$result"
}

# ─── Analyze Issue Complexity ──────────────────────────────────────────────
decompose_analyze() {
    local issue_num="$1"

    if [[ "$NO_GITHUB" == "true" ]]; then
        # Mock data for testing (JSON only, no messages)
        echo '{
            "issue_number": '$issue_num',
            "complexity_score": 85,
            "estimated_hours": 12,
            "should_decompose": true,
            "reasoning": "Issue involves major architectural changes",
            "subtasks": [
                {
                    "title": "Subtask 1: Design phase",
                    "description": "Plan and document the new architecture"
                },
                {
                    "title": "Subtask 2: Implementation phase",
                    "description": "Implement core changes"
                },
                {
                    "title": "Subtask 3: Integration & testing",
                    "description": "Integrate changes and add tests"
                }
            ]
        }'
        return 0
    fi

    # Fetch issue details
    local issue_json
    issue_json=$(gh issue view "$issue_num" --json number,title,body,labels 2>/dev/null || echo "")

    if [[ -z "$issue_json" ]]; then
        error "Could not fetch issue #${issue_num}"
        return 1
    fi

    local issue_title
    issue_title=$(echo "$issue_json" | jq -r '.title' 2>/dev/null || echo "")

    local issue_body
    issue_body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null | head -500 || echo "")

    local issue_labels
    issue_labels=$(echo "$issue_json" | jq -r '.labels[].name' 2>/dev/null | tr '\n' ',' || echo "")

    # Build prompt for Claude
    local prompt
    read -r -d '' prompt <<'PROMPT' || true
You are an issue complexity analyzer. Analyze the GitHub issue below and determine:
1. Complexity score (1-100): How intricate/multi-faceted is the work?
2. Estimated hours (1-100): How long would this realistically take?
3. Should decompose: Is complexity > 70 OR hours > 8?
4. If should decompose: Generate 3-5 focused, independent subtasks

Each subtask should be:
- Self-contained (can be worked on independently)
- Completable in one pipeline run (~20 iterations max)
- Have clear acceptance criteria
- Include test strategy

Return ONLY valid JSON (no markdown, no explanation):
{
    "issue_number": <number>,
    "complexity_score": <1-100>,
    "estimated_hours": <1-100>,
    "should_decompose": <true|false>,
    "reasoning": "<brief explanation>",
    "subtasks": [
        {
            "title": "Subtask N: <clear title>",
            "description": "<1-2 sentences describing the work>",
            "acceptance_criteria": ["criterion 1", "criterion 2"],
            "test_approach": "<how to validate this subtask>"
        }
    ]
}

ISSUE #<issue_number>:
Title: <issue_title>
Body:
<issue_body>
Labels: <issue_labels>
PROMPT

    # Replace placeholders
    prompt="${prompt//<issue_number>/$issue_num}"
    prompt="${prompt//<issue_title>/$issue_title}"
    prompt="${prompt//<issue_body>/$issue_body}"
    prompt="${prompt//<issue_labels>/$issue_labels}"

    # Call Claude
    local result
    result=$(_decompose_call_claude "$prompt")

    if [[ "$result" == *"error"* ]]; then
        error "Claude analysis failed"
        return 1
    fi

    echo "$result"
    emit_event "decompose.analyzed" "issue=$issue_num" "result=$result"
}

# ─── Create Subtask Issues ──────────────────────────────────────────────────
decompose_create_subtasks() {
    local issue_num="$1"
    local analysis_json="$2"

    if [[ "$NO_GITHUB" == "true" ]]; then
        # Return mock subtask numbers (JSON-clean output only)
        echo "123 124 125"
        return 0
    fi

    # Fetch parent issue details for label inheritance
    local parent_labels parent_title
    parent_labels=$(gh issue view "$issue_num" --json labels --jq '.labels[].name' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")
    parent_title=$(gh issue view "$issue_num" --json title --jq '.title' 2>/dev/null || echo "")

    # Extract subtasks from analysis
    local subtask_count
    subtask_count=$(echo "$analysis_json" | jq '.subtasks | length' 2>/dev/null || echo "0")

    if [[ "$subtask_count" -eq 0 ]]; then
        return 1
    fi

    local created_issue_nums=""
    local idx=1

    while [[ "$idx" -le "$subtask_count" ]]; do
        local subtask
        subtask=$(echo "$analysis_json" | jq ".subtasks[$((idx - 1))]" 2>/dev/null || echo "{}")

        local subtask_title
        subtask_title=$(echo "$subtask" | jq -r '.title // ""' 2>/dev/null || echo "")

        if [[ -z "$subtask_title" ]]; then
            error "  Subtask #$idx: missing title"
            idx=$((idx + 1))
            continue
        fi

        # Build subtask description with acceptance criteria and test approach
        local subtask_description
        local acceptance_criteria
        local test_approach

        acceptance_criteria=$(echo "$subtask" | jq -r '.acceptance_criteria[]? // empty' 2>/dev/null | sed 's/^/- /' || echo "")
        test_approach=$(echo "$subtask" | jq -r '.test_approach // ""' 2>/dev/null || echo "")

        read -r -d '' subtask_description <<SUBEOF || true
## Description
$(echo "$subtask" | jq -r '.description // ""' 2>/dev/null)

## Part of
Issue #${issue_num}: ${parent_title}

## Acceptance Criteria
${acceptance_criteria:-None specified}

## Test Approach
${test_approach:-Run standard test suite}
SUBEOF

        # Create the subtask issue
        local create_labels="${parent_labels}"
        if [[ -n "$create_labels" ]]; then
            create_labels="${create_labels},${DECOMPOSE_LABEL}"
        else
            create_labels="$DECOMPOSE_LABEL"
        fi

        local subtask_issue_num
        if subtask_issue_num=$(gh issue create \
            --title "$subtask_title" \
            --body "$subtask_description" \
            --label "$create_labels" 2>/dev/null); then

            created_issue_nums="${created_issue_nums}${subtask_issue_num} "
            emit_event "decompose.subtask_created" "parent=$issue_num" "subtask=$subtask_issue_num"
        fi

        idx=$((idx + 1))
    done

    echo "${created_issue_nums% }"
}

# ─── Add Comment to Parent Issue ────────────────────────────────────────────
decompose_add_parent_comment() {
    local issue_num="$1"
    local subtask_nums="$2"

    if [[ "$NO_GITHUB" == "true" ]]; then
        return 0
    fi

    # Build comment with subtask links
    local comment_body="## 🔄 Decomposed into subtasks

This issue was too ambitious for a single pipeline run. It has been decomposed into smaller, focused subtasks:

"

    for subtask_num in $subtask_nums; do
        comment_body="${comment_body}- #${subtask_num}
"
    done

    comment_body="${comment_body}
Each subtask can be completed independently and merged gradually. Close this issue once all subtasks are complete."

    if gh issue comment "$issue_num" --body "$comment_body" 2>/dev/null; then
        success "Added decomposition comment to issue #$issue_num"
        return 0
    else
        warn "Failed to add comment to issue #$issue_num"
        return 1
    fi
}

# ─── Add Decomposed Label ───────────────────────────────────────────────────
decompose_mark_decomposed() {
    local issue_num="$1"

    if [[ "$NO_GITHUB" == "true" ]]; then
        return 0
    fi

    if gh issue edit "$issue_num" --add-label "$DECOMPOSED_MARKER_LABEL" 2>/dev/null; then
        success "Marked issue #$issue_num as decomposed"
        return 0
    else
        warn "Failed to add decomposed label to issue #$issue_num"
        return 1
    fi
}

# ─── Main: Analyze Only ─────────────────────────────────────────────────────
cmd_analyze() {
    local issue_num="${1:-}"

    if [[ -z "$issue_num" ]]; then
        error "Usage: sw-decompose.sh analyze <issue-number>"
        return 1
    fi

    echo ""
    info "Issue Complexity Analysis"
    info "Analyzing issue #${issue_num}..."
    echo ""

    local analysis
    analysis=$(decompose_analyze "$issue_num") || return 1

    # Pretty-print the JSON result
    echo "$analysis" | jq '.' 2>/dev/null || echo "$analysis"

    echo ""
    local should_decompose
    should_decompose=$(echo "$analysis" | jq '.should_decompose' 2>/dev/null || echo "false")

    if [[ "$should_decompose" == "true" ]]; then
        local complexity
        complexity=$(echo "$analysis" | jq '.complexity_score' 2>/dev/null || echo "0")
        local hours
        hours=$(echo "$analysis" | jq '.estimated_hours' 2>/dev/null || echo "0")
        warn "Issue is too ambitious (complexity=${complexity}, hours=${hours})"
        echo "Run 'sw decompose $issue_num' to auto-create subtasks"
    else
        success "Issue is simple enough for a single pipeline run"
    fi
}

# ─── Main: Decompose & Create Subtasks ──────────────────────────────────────
cmd_decompose() {
    local issue_num="${1:-}"

    if [[ -z "$issue_num" ]]; then
        error "Usage: sw-decompose.sh decompose <issue-number>"
        return 1
    fi

    echo ""
    info "Decomposing Issue #${issue_num}"
    echo ""

    # Check if already decomposed
    if _has_label "$issue_num" "$DECOMPOSED_MARKER_LABEL"; then
        warn "Issue #$issue_num is already marked as decomposed"
        return 0
    fi

    # Analyze
    local analysis
    analysis=$(decompose_analyze "$issue_num") || return 1

    local should_decompose
    should_decompose=$(echo "$analysis" | jq '.should_decompose' 2>/dev/null || echo "false")

    if [[ "$should_decompose" != "true" ]]; then
        success "Issue #$issue_num is simple enough — no decomposition needed"
        emit_event "decompose.skipped" "issue=$issue_num" "reason=simple"
        return 0
    fi

    # Create subtasks
    info "Creating subtask issues..."
    local subtask_nums
    subtask_nums=$(decompose_create_subtasks "$issue_num" "$analysis") || return 1

    if [[ -z "$subtask_nums" ]]; then
        error "No subtasks were created"
        return 1
    fi

    # Add parent comment
    decompose_add_parent_comment "$issue_num" "$subtask_nums"

    # Mark as decomposed
    decompose_mark_decomposed "$issue_num"

    echo ""
    local subtask_count
    subtask_count=$(echo "$subtask_nums" | wc -w)
    success "Issue #$issue_num decomposed into $subtask_count subtasks:"
    for subtask_num in $subtask_nums; do
        echo "  - #$subtask_num"
    done

    emit_event "decompose.completed" "issue=$issue_num" "subtask_count=$(echo $subtask_nums | wc -w)"
}

# ─── Main: Auto (for daemon) ────────────────────────────────────────────────
cmd_auto() {
    local issue_num="${1:-}"

    if [[ -z "$issue_num" ]]; then
        error "Usage: sw-decompose.sh auto <issue-number>"
        return 1
    fi

    # Check if already decomposed
    if _has_label "$issue_num" "$DECOMPOSED_MARKER_LABEL"; then
        return 0
    fi

    # Analyze
    local analysis
    analysis=$(decompose_analyze "$issue_num") || return 1

    local should_decompose
    should_decompose=$(echo "$analysis" | jq '.should_decompose' 2>/dev/null || echo "false")

    if [[ "$should_decompose" != "true" ]]; then
        return 0
    fi

    # Create subtasks
    local subtask_nums
    subtask_nums=$(decompose_create_subtasks "$issue_num" "$analysis") || return 1

    if [[ -z "$subtask_nums" ]]; then
        return 1
    fi

    # Add parent comment
    decompose_add_parent_comment "$issue_num" "$subtask_nums"

    # Mark as decomposed
    decompose_mark_decomposed "$issue_num"

    emit_event "decompose.auto_completed" "issue=$issue_num" "subtask_count=$(echo $subtask_nums | wc -w)"

    return 0
}

# ─── CLI Router ──────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-help}"

    case "$cmd" in
        analyze)
            cmd_analyze "${2:-}"
            ;;
        decompose)
            cmd_decompose "${2:-}"
            ;;
        auto)
            cmd_auto "${2:-}"
            ;;
        help|--help|-h)
            echo ""
            echo -e "${CYAN}${BOLD}shipwright decompose${RESET} — Issue Complexity Analysis & Decomposition"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  ${CYAN}sw decompose${RESET} <command> <issue-number>"
            echo ""
            echo -e "${BOLD}COMMANDS${RESET}"
            echo -e "  ${CYAN}analyze${RESET} <num>     Analyze complexity without creating issues"
            echo -e "  ${CYAN}decompose${RESET} <num>   Analyze + create subtask issues if needed"
            echo -e "  ${CYAN}auto${RESET} <num>        Daemon mode: silent decomposition (returns 0)"
            echo ""
            echo -e "${BOLD}EXAMPLES${RESET}"
            echo -e "  ${DIM}sw decompose analyze 42${RESET}    # See complexity score and reasoning"
            echo -e "  ${DIM}sw decompose decompose 42${RESET}  # Create subtasks for issue #42"
            echo -e "  ${DIM}sw decompose auto 42${RESET}       # Used by daemon (no output)"
            echo ""
            ;;
        --version|-v)
            echo "sw-decompose $VERSION"
            ;;
        *)
            error "Unknown command: $cmd"
            echo "Run 'sw decompose help' for usage"
            exit 1
            ;;
    esac
}

# ─── Guard: only run main if not sourced ──────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
