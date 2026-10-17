#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright decompose — Intelligent Issue Decomposition                  ║
# ║  Analyze complexity · Auto-create subtasks · Track progress             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# Agents run without GitHub credentials (#8614): claude is launched through agent-exec.sh.
SW_AGENT_EXEC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-exec.sh"
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

# shellcheck disable=SC2034
VERSION="3.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cross-platform compatibility ──────────────────────────────────────────
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Issue intake caps for automated filings (ADR-0007); path is relative to this file
# shellcheck source=lib/safety-gates.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/safety-gates.sh"
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
    local payload
    payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
# ─── Structured Event Log ──────────────────────────────────────────────────
# shellcheck disable=SC2034
EVENTS_FILE="${HOME}/.shipwright/events.jsonl"

# ─── Configuration ─────────────────────────────────────────────────────────
# shellcheck disable=SC2034
COMPLEXITY_THRESHOLD=70          # Decompose if complexity > this
# shellcheck disable=SC2034
HOURS_THRESHOLD=8                # Decompose if estimated hours > this
# shellcheck disable=SC2034
MIN_SUBTASKS=3
DECOMPOSE_LABEL="subtask"
# At most this many subtask issues per parent; the rest are refused (logged)
DECOMPOSE_MAX_SUBTASKS="${DECOMPOSE_MAX_SUBTASKS:-8}"
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
    if ! response=$("$SW_AGENT_EXEC" claude --print --max-turns 1 "$prompt" 2>/dev/null); then
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
        # Mock data for testing with dependencies for DAG features
        echo '{
            "issue_number": '$issue_num',
            "complexity_score": 85,
            "estimated_hours": 12,
            "should_decompose": true,
            "reasoning": "Issue involves major architectural changes",
            "subtasks": [
                {
                    "title": "Subtask 1: Design phase",
                    "description": "Plan and document the new architecture",
                    "acceptance_criteria": ["Design approved", "Architecture documented"],
                    "test_approach": "Code review",
                    "depends_on": [],
                    "estimated_hours": 3
                },
                {
                    "title": "Subtask 2: Implementation phase",
                    "description": "Implement core changes",
                    "acceptance_criteria": ["Core features working", "Tests pass"],
                    "test_approach": "Unit tests",
                    "depends_on": [0],
                    "estimated_hours": 6
                },
                {
                    "title": "Subtask 3: Integration & testing",
                    "description": "Integrate changes and add tests",
                    "acceptance_criteria": ["Integration complete", "E2E tests pass"],
                    "test_approach": "Integration tests",
                    "depends_on": [1],
                    "estimated_hours": 3
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
4. If should decompose: Generate 3-5 focused subtasks with explicit dependencies

For dependencies (DAG scheduling):
- Index subtasks 0, 1, 2, ... in array order
- Each subtask lists indices of tasks it depends on in "depends_on" array
- Empty "depends_on" means no dependencies (can start immediately)
- Task N can only depend on tasks 0..N-1 (no circular dependencies)
- Examples: task 2 depends on [0, 1]; task 1 depends on [0]; task 0 depends on []

Each subtask should be:
- Self-contained (can be worked on after dependencies complete)
- Completable in one pipeline run (~20 iterations max)
- Have clear acceptance criteria
- Include test strategy
- Have realistic estimated_hours for critical path analysis

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
            "test_approach": "<how to validate this subtask>",
            "depends_on": [<list of task indices, or empty>],
            "estimated_hours": <1-100>
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
    if [[ "$subtask_count" -gt "$DECOMPOSE_MAX_SUBTASKS" ]]; then
        warn "  ${subtask_count} subtasks proposed; filing the first ${DECOMPOSE_MAX_SUBTASKS}, refusing the rest"
        emit_event "decompose.subtasks_capped" "parent=$issue_num" "proposed=$subtask_count" "max=$DECOMPOSE_MAX_SUBTASKS"
        subtask_count="$DECOMPOSE_MAX_SUBTASKS"
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
        if subtask_issue_num=$(patrol_issue_create --intake-label "$DECOMPOSE_LABEL" \
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

# ─── DAG Validation: Check for cycles ──────────────────────────────────────
decompose_validate_dag() {
    local analysis_json="$1"

    # Validate DAG structure: all depends_on indices must be < current index (no cycles)
    jq -c '
        .subtasks as $tasks |
        ($tasks | length) as $n |
        (
            reduce range(0; $n) as $i (
                {"valid": true, "error": null};
                if .valid then
                    (
                        $tasks[$i].depends_on // []
                    ) as $deps |
                    (
                        reduce $deps[] as $dep (
                            .;
                            if (.valid) then
                                if $dep >= $i then
                                    .valid = false |
                                    .error = "invalid_dependency: task \($i) depends on task \($dep) at same or later index"
                                elif $dep < 0 or $dep >= $n then
                                    .valid = false |
                                    .error = "out_of_range: task \($i) depends on nonexistent task \($dep)"
                                else . end
                            else . end
                        )
                    )
                else . end
            )
        )
    ' <<< "$analysis_json" 2>/dev/null || echo '{"valid": false, "error": "json_parse_error"}'
}

# ─── Topological Sort: Order subtasks into execution waves ──────────────────
decompose_topo_sort() {
    local analysis_json="$1"

    # Validate DAG first
    local validation
    validation=$(decompose_validate_dag "$analysis_json")
    if [[ "$(echo "$validation" | jq -r '.valid' 2>/dev/null)" != "true" ]]; then
        error "DAG validation failed: $(echo "$validation" | jq -r '.error' 2>/dev/null)"
        echo '{"error": "invalid_dag"}'
        return 1
    fi

    # Calculate depth (wave) for each task: max depth of dependencies + 1
    jq -c '
        .subtasks as $tasks |
        ($tasks | length) as $n |
        (
            reduce range(0; $n) as $i (
                {};
                . as $depths |
                (
                    if ($tasks[$i].depends_on // [] | length) == 0 then
                        0
                    else
                        ([ $tasks[$i].depends_on[] | $depths[. | tostring] // 0 ] | max) + 1
                    end
                ) as $depth |
                $depths + {($i | tostring): $depth}
            )
        ) as $depths |
        (
            # Group tasks by depth (wave)
            reduce range(0; $n) as $i (
                {};
                . as $wave_map |
                ($depths[$i | tostring] | tostring) as $wave_key |
                $wave_map + {($wave_key): (($wave_map[$wave_key] // []) + [$i])}
            )
        ) as $wave_map |
        (
            # Convert to array of waves, sorted
            [
                ($wave_map | keys[] | tonumber) as $wave |
                {
                    "wave": ($wave + 1),
                    "tasks": ($wave_map[$wave | tostring] | sort)
                }
            ] | sort_by(.wave)
        ) |
        {
            "waves": .,
            "total_tasks": $n,
            "max_wave": (map(.wave) | max)
        }
    ' <<< "$analysis_json" 2>/dev/null
}

# ─── Critical Path Analysis: Find bottleneck tasks ──────────────────────────
decompose_critical_path() {
    local analysis_json="$1"

    # Sum estimated_hours for all tasks as total critical path
    jq -c '{
        "critical_path_hours": ([.subtasks[].estimated_hours // 1] | add),
        "total_tasks": (.subtasks | length),
        "bottleneck_tasks": (
            [
                range(0; .subtasks | length) as $i |
                select(.subtasks[$i].estimated_hours // 1 >= 4) |
                {
                    "index": $i,
                    "title": .subtasks[$i].title,
                    "hours": (.subtasks[$i].estimated_hours // 1)
                }
            ]
        )
    }' <<< "$analysis_json" 2>/dev/null
}

# ─── DAG Visualization: Render as ASCII or Mermaid ──────────────────────────
decompose_visualize() {
    local analysis_json="$1"
    local format="${2:-text}"

    case "$format" in
        text)
            jq -r '
                .subtasks as $tasks |
                "Dependencies DAG - Issue " + (.issue_number | tostring) + "\n" +
                "==================================================\n" +
                (
                    reduce range(0; $tasks | length) as $i (
                        "";
                        . + "[\($i)] \($tasks[$i].title)\n" +
                        (
                            if ($tasks[$i].depends_on // [] | length) > 0 then
                                "    depends on: \($tasks[$i].depends_on | map("[" + (. | tostring) + "]") | join(", "))\n"
                            else
                                "    (no dependencies)\n"
                            end
                        )
                    )
                )
            ' <<< "$analysis_json" 2>/dev/null
            ;;
        mermaid)
            jq -r '
                .subtasks as $tasks |
                "graph TD\n" +
                (
                    reduce range(0; $tasks | length) as $i (
                        "";
                        . + "  task\($i)[\"[\($i)] \($tasks[$i].title)\"]\n" +
                        (
                            if ($tasks[$i].depends_on // [] | length) > 0 then
                                ($tasks[$i].depends_on | map("  task\(.) --> task\($i)\n") | join(""))
                            else "" end
                        )
                    )
                )
            ' <<< "$analysis_json" 2>/dev/null
            ;;
        *)
            error "Unknown format: $format (use 'text' or 'mermaid')"
            return 1
            ;;
    esac
}

# ─── Schedule Creation: Generate execution plan ──────────────────────────────
decompose_schedule() {
    local analysis_json="$1"
    local parent_issue="${2:-}"

    # Get topological sort with waves
    local waves_json
    waves_json=$(decompose_topo_sort "$analysis_json") || return 1

    # Create schedule file
    local state_file
    state_file="${REPO_DIR}/.claude/pipeline-artifacts/decompose-schedule-$(date +%s).json"
    mkdir -p "$(dirname "$state_file")"

    # Write schedule state
    jq -c '{
        "issue": ('$parent_issue'),
        "created_at": now | todate,
        "waves": .waves,
        "task_status": (
            reduce range(0; .total_tasks) as $i (
                {};
                . + {($i | tostring): "pending"}
            )
        )
    }' <<< "$waves_json" > "$state_file"

    info "Schedule created: $(jq '.total_tasks' <<< "$waves_json") tasks in $(jq '.max_wave' <<< "$waves_json") waves"
    echo "$state_file"
    emit_event "decompose.scheduled" "issue=$parent_issue" "total_tasks=$(jq '.total_tasks' <<< "$waves_json")" "waves=$(jq '.max_wave' <<< "$waves_json")"
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

# ─── Main: Visualize DAG ────────────────────────────────────────────────────
cmd_visualize() {
    local json_file="${1:-}"
    local format="${2:-text}"

    if [[ -z "$json_file" ]]; then
        error "Usage: sw-decompose.sh visualize <analysis-json-file> [text|mermaid]"
        return 1
    fi

    if [[ ! -f "$json_file" ]]; then
        error "File not found: $json_file"
        return 1
    fi

    echo ""
    decompose_visualize "$(cat "$json_file")" "$format" || return 1
    echo ""
    emit_event "decompose.visualized" "file=$json_file" "format=$format"
}

# ─── Main: Critical Path Analysis ───────────────────────────────────────────
cmd_critical_path() {
    local json_file="${1:-}"

    if [[ -z "$json_file" ]]; then
        error "Usage: sw-decompose.sh critical-path <analysis-json-file>"
        return 1
    fi

    if [[ ! -f "$json_file" ]]; then
        error "File not found: $json_file"
        return 1
    fi

    echo ""
    info "Critical Path Analysis"
    echo ""

    decompose_critical_path "$(cat "$json_file")" | jq '.' 2>/dev/null || return 1

    echo ""
    emit_event "decompose.critical_path_analyzed" "file=$json_file"
}

# ─── Main: DAG Scheduling ──────────────────────────────────────────────────
cmd_schedule() {
    local json_file="${1:-}"
    local parent_issue="${2:-}"

    if [[ -z "$json_file" ]]; then
        error "Usage: sw-decompose.sh schedule <analysis-json-file> [issue-number]"
        return 1
    fi

    if [[ ! -f "$json_file" ]]; then
        error "File not found: $json_file"
        return 1
    fi

    local json_content
    json_content=$(cat "$json_file")

    # Extract issue number if not provided
    if [[ -z "$parent_issue" ]]; then
        parent_issue=$(echo "$json_content" | jq -r '.issue_number' 2>/dev/null || echo "")
    fi

    echo ""
    info "DAG Scheduling"
    echo ""

    # Validate DAG
    local validation
    validation=$(decompose_validate_dag "$json_content")
    if [[ "$(echo "$validation" | jq -r '.valid' 2>/dev/null)" != "true" ]]; then
        error "Invalid DAG: $(echo "$validation" | jq -r '.error' 2>/dev/null)"
        return 1
    fi
    success "DAG is acyclic"
    echo ""

    # Show visualization
    decompose_visualize "$json_content" "text"
    echo ""

    # Get topological sort
    local waves
    waves=$(decompose_topo_sort "$json_content") || return 1

    info "Execution Waves:"
    echo "$waves" | jq -r '.waves[] | "  Wave \(.wave): Tasks \(.tasks | map("[" + (. | tostring) + "]") | join(", "))"'
    echo ""

    # Create schedule
    local schedule_file
    schedule_file=$(decompose_schedule "$json_content" "$parent_issue") || return 1

    success "Schedule saved to: $schedule_file"
    echo ""
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
        schedule)
            cmd_schedule "${2:-}" "${3:-}"
            ;;
        critical-path)
            cmd_critical_path "${2:-}"
            ;;
        visualize)
            cmd_visualize "${2:-}" "${3:-text}"
            ;;
        help|--help|-h)
            echo ""
            echo -e "${CYAN}${BOLD}shipwright decompose${RESET} — Issue Complexity & DAG Scheduling"
            echo ""
            echo -e "${BOLD}USAGE${RESET}"
            echo -e "  ${CYAN}sw decompose${RESET} <command> [options]"
            echo ""
            echo -e "${BOLD}COMMANDS${RESET}"
            echo -e "  ${CYAN}analyze${RESET} <num>              Analyze complexity without creating issues"
            echo -e "  ${CYAN}decompose${RESET} <num>            Analyze + create subtask issues if needed"
            echo -e "  ${CYAN}auto${RESET} <num>                 Daemon mode: silent decomposition"
            echo -e "  ${CYAN}schedule${RESET} <file> [issue]     Create execution schedule from analysis JSON"
            echo -e "  ${CYAN}critical-path${RESET} <file>        Analyze critical path (bottlenecks)"
            echo -e "  ${CYAN}visualize${RESET} <file> [fmt]      Render DAG (text or mermaid format)"
            echo ""
            echo -e "${BOLD}EXAMPLES${RESET}"
            echo -e "  ${DIM}sw decompose analyze 42${RESET}"
            echo -e "  ${DIM}sw decompose decompose 42${RESET}"
            echo -e "  ${DIM}sw decompose schedule analysis.json 42${RESET}"
            echo -e "  ${DIM}sw decompose critical-path analysis.json${RESET}"
            echo -e "  ${DIM}sw decompose visualize analysis.json mermaid${RESET}"
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
