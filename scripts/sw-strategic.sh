#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-strategic.sh — Strategic Intelligence Agent                         ║
# ║  Reads strategy, metrics, and codebase to create high-impact issues     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file can be BOTH sourced (by sw-daemon.sh) and run standalone.
# When sourced, do NOT add set -euo pipefail — the parent handles that.
# When run directly, main() sets up the error handling.

VERSION="1.10.0"

# ─── Colors (matches Seth's tmux theme) ─────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
BLUE='\033[38;2;0;102;255m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Helpers (define fallbacks if not provided by parent) ─────────────────────
# When sourced by sw-daemon.sh, these are already defined. When run standalone
# or sourced by tests, we define them here.
type info &>/dev/null 2>&1 || info()    { echo -e "${CYAN}${BOLD}▸${RESET} $*"; }
type success &>/dev/null 2>&1 || success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
type warn &>/dev/null 2>&1 || warn()    { echo -e "${YELLOW}${BOLD}⚠${RESET} $*"; }
type error &>/dev/null 2>&1 || error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }
type now_epoch &>/dev/null 2>&1 || now_epoch() { date +%s; }
type now_iso &>/dev/null 2>&1 || now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# ─── Paths (set defaults if not provided by parent) ──────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

if ! type emit_event &>/dev/null 2>&1; then
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
                local escaped_val
                escaped_val=$(printf '%s' "$val" | jq -Rs '.' 2>/dev/null || printf '"%s"' "${val//\"/\\\"}")
                json_fields="${json_fields},\"${key}\":${escaped_val}"
            fi
        done
        mkdir -p "${HOME}/.shipwright"
        echo "{\"ts\":\"$(now_iso)\",\"ts_epoch\":$(now_epoch),\"type\":\"${event_type}\"${json_fields}}" >> "$EVENTS_FILE"
    }
fi

# ─── Constants ────────────────────────────────────────────────────────────────
STRATEGIC_MAX_ISSUES=3
STRATEGIC_COOLDOWN_SECONDS=43200  # 12 hours
STRATEGIC_MODEL="claude-haiku-4-5-20251001"
STRATEGIC_MAX_TOKENS=2048
STRATEGIC_STRATEGY_LINES=200

# ─── Cooldown Check ──────────────────────────────────────────────────────────
strategic_check_cooldown() {
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"
    if [[ ! -f "$events_file" ]]; then
        return 0  # No events file — no cooldown
    fi

    local now_e
    now_e=$(now_epoch)
    local last_run
    last_run=$(grep '"strategic.cycle_complete"' "$events_file" 2>/dev/null | tail -1 | jq -r '.ts_epoch // 0' 2>/dev/null || echo "0")

    local elapsed=$(( now_e - last_run ))
    if [[ "$elapsed" -lt "$STRATEGIC_COOLDOWN_SECONDS" ]]; then
        local remaining=$(( (STRATEGIC_COOLDOWN_SECONDS - elapsed) / 60 ))
        info "Strategic cooldown active — ${remaining} minutes remaining"
        return 1
    fi
    return 0
}

# ─── Gather Context ──────────────────────────────────────────────────────────
strategic_gather_context() {
    local repo_dir="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local script_dir="${SCRIPT_DIR:-${repo_dir}/scripts}"
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

    # 1. Read STRATEGY.md (truncated)
    local strategy_content=""
    if [[ -f "${repo_dir}/STRATEGY.md" ]]; then
        strategy_content=$(head -n "$STRATEGIC_STRATEGY_LINES" "${repo_dir}/STRATEGY.md")
    else
        strategy_content="(No STRATEGY.md found)"
    fi

    # 2. Codebase stats
    local total_scripts=0
    local untested_scripts=""
    local untested_count=0
    local total_tests=0

    for script in "$script_dir"/sw-*.sh; do
        [[ ! -f "$script" ]] && continue
        local base
        base=$(basename "$script" .sh)
        [[ "$base" == *-test ]] && continue
        [[ "$base" == sw-tracker-linear ]] && continue
        [[ "$base" == sw-tracker-jira ]] && continue
        [[ "$base" == sw-patrol-meta ]] && continue
        [[ "$base" == sw-strategic ]] && continue
        total_scripts=$((total_scripts + 1))

        local test_file="$script_dir/${base}-test.sh"
        if [[ -f "$test_file" ]]; then
            total_tests=$((total_tests + 1))
        else
            untested_count=$((untested_count + 1))
            untested_scripts="${untested_scripts}  - ${base}.sh\n"
        fi
    done

    # 3. Pipeline performance (last 7 days)
    local completed=0
    local failed=0
    local success_rate="N/A"
    local common_failures=""

    if [[ -f "$events_file" ]]; then
        local now_e
        now_e=$(now_epoch)
        local seven_days_ago=$(( now_e - 604800 ))

        completed=$(jq -s "[.[] | select(.type == \"pipeline.completed\" and .result == \"success\" and (.ts_epoch // 0) >= $seven_days_ago)] | length" "$events_file" 2>/dev/null || echo "0")
        failed=$(jq -s "[.[] | select(.type == \"pipeline.completed\" and .result != \"success\" and (.ts_epoch // 0) >= $seven_days_ago)] | length" "$events_file" 2>/dev/null || echo "0")

        local total_pipelines=$(( completed + failed ))
        if [[ "$total_pipelines" -gt 0 ]]; then
            success_rate=$(( completed * 100 / total_pipelines ))
            success_rate="${success_rate}%"
        fi

        common_failures=$(jq -s "
            [.[] | select(.type == \"pipeline.completed\" and .result != \"success\" and (.ts_epoch // 0) >= $seven_days_ago)]
            | group_by(.failed_stage // \"unknown\")
            | map({stage: .[0].failed_stage // \"unknown\", count: length})
            | sort_by(-.count)
            | .[0:5]
            | map(\"\(.stage) (\(.count)x)\")
            | join(\", \")
        " "$events_file" 2>/dev/null || echo "none")
    fi

    # 4. Open issues
    local open_issues=""
    if [[ "${NO_GITHUB:-false}" != "true" ]]; then
        open_issues=$(gh issue list --state open --json number,title,labels --jq '.[] | "#\(.number): \(.title) [\(.labels | map(.name) | join(","))]"' 2>/dev/null | head -50 || echo "(could not fetch issues)")
    else
        open_issues="(GitHub access disabled)"
    fi

    # Build the context output
    printf '%s\n' "STRATEGY_CONTENT<<EOF"
    printf '%s\n' "$strategy_content"
    printf '%s\n' "EOF"
    printf '%s\n' "TOTAL_SCRIPTS=${total_scripts}"
    printf '%s\n' "TOTAL_TESTS=${total_tests}"
    printf '%s\n' "UNTESTED_COUNT=${untested_count}"
    printf '%s\n' "UNTESTED_SCRIPTS<<EOF"
    printf '%b' "$untested_scripts"
    printf '%s\n' "EOF"
    printf '%s\n' "PIPELINES_COMPLETED=${completed}"
    printf '%s\n' "PIPELINES_FAILED=${failed}"
    printf '%s\n' "SUCCESS_RATE=${success_rate}"
    printf '%s\n' "COMMON_FAILURES=${common_failures}"
    printf '%s\n' "OPEN_ISSUES<<EOF"
    printf '%s\n' "$open_issues"
    printf '%s\n' "EOF"
}

# ─── Build Prompt ─────────────────────────────────────────────────────────────
strategic_build_prompt() {
    local repo_dir="${REPO_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
    local script_dir="${SCRIPT_DIR:-${repo_dir}/scripts}"
    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

    # Read STRATEGY.md
    local strategy_content=""
    if [[ -f "${repo_dir}/STRATEGY.md" ]]; then
        strategy_content=$(head -n "$STRATEGIC_STRATEGY_LINES" "${repo_dir}/STRATEGY.md")
    else
        strategy_content="(No STRATEGY.md found)"
    fi

    # Codebase stats
    local total_scripts=0
    local untested_list=""
    local untested_count=0
    local total_tests=0

    for script in "$script_dir"/sw-*.sh; do
        [[ ! -f "$script" ]] && continue
        local base
        base=$(basename "$script" .sh)
        [[ "$base" == *-test ]] && continue
        [[ "$base" == sw-tracker-linear ]] && continue
        [[ "$base" == sw-tracker-jira ]] && continue
        [[ "$base" == sw-patrol-meta ]] && continue
        [[ "$base" == sw-strategic ]] && continue
        total_scripts=$((total_scripts + 1))

        if [[ -f "$script_dir/${base}-test.sh" ]]; then
            total_tests=$((total_tests + 1))
        else
            untested_count=$((untested_count + 1))
            untested_list="${untested_list}\n  - ${base}.sh"
        fi
    done

    # Pipeline performance (last 7 days)
    local completed=0 failed=0 success_rate="N/A" common_failures="none"
    if [[ -f "$events_file" ]]; then
        local now_e
        now_e=$(now_epoch)
        local seven_days_ago=$(( now_e - 604800 ))

        completed=$(jq -s "[.[] | select(.type == \"pipeline.completed\" and .result == \"success\" and (.ts_epoch // 0) >= $seven_days_ago)] | length" "$events_file" 2>/dev/null || echo "0")
        failed=$(jq -s "[.[] | select(.type == \"pipeline.completed\" and .result != \"success\" and (.ts_epoch // 0) >= $seven_days_ago)] | length" "$events_file" 2>/dev/null || echo "0")

        local total_pipelines=$(( completed + failed ))
        if [[ "$total_pipelines" -gt 0 ]]; then
            success_rate="$(( completed * 100 / total_pipelines ))%"
        fi

        common_failures=$(jq -s "
            [.[] | select(.type == \"pipeline.completed\" and .result != \"success\" and (.ts_epoch // 0) >= $seven_days_ago)]
            | group_by(.failed_stage // \"unknown\")
            | map({stage: .[0].failed_stage // \"unknown\", count: length})
            | sort_by(-.count)
            | .[0:5]
            | map(\"\(.stage) (\(.count)x)\")
            | join(\", \")
        " "$events_file" 2>/dev/null || echo "none")
        # Empty string → "none"
        common_failures="${common_failures:-none}"
    fi

    # Open issues
    local open_issues=""
    if [[ "${NO_GITHUB:-false}" != "true" ]]; then
        open_issues=$(gh issue list --state open --json number,title --jq '.[] | "#\(.number): \(.title)"' 2>/dev/null | head -50 || echo "(could not fetch)")
    else
        open_issues="(GitHub access disabled)"
    fi

    # Compose the prompt
    cat <<PROMPT_EOF
You are the Strategic PM for Shipwright — an autonomous software delivery system. Your job is to analyze the current state and recommend 1-3 high-impact improvements to build next.

## Strategy (from STRATEGY.md)
${strategy_content}

## Current Codebase
- Total scripts: ${total_scripts}
- Scripts with tests: ${total_tests}
- Scripts without tests (${untested_count}):$(echo -e "$untested_list")

## Recent Pipeline Performance (last 7 days)
- Pipelines completed successfully: ${completed}
- Pipelines failed: ${failed}
- Success rate: ${success_rate}
- Common failure stages: ${common_failures}

## Open Issues (already in progress — do NOT duplicate these)
${open_issues}

## Your Task
Based on the strategy priorities and current data, recommend 1-3 concrete improvements to build next. Each should be a single, well-scoped task completable by one autonomous pipeline run.

For each recommendation, provide EXACTLY this format (no extra fields, no deviations):

ISSUE_TITLE: <concise, actionable title>
PRIORITY: <P0|P1|P2|P3|P4|P5>
COMPLEXITY: <fast|standard|full>
STRATEGY_AREA: <which priority area from strategy, e.g. "P0: Reliability">
DESCRIPTION: <2-3 sentences describing what to build and why it matters>
ACCEPTANCE: <bullet list of acceptance criteria, one per line starting with "- ">
---

Rules:
- Do NOT duplicate any open issue listed above
- Prioritize based on STRATEGY.md priorities (P0 > P1 > P2 > ...)
- Focus on concrete, actionable improvements (not vague goals)
- Each issue should be completable by one autonomous pipeline run
- Prefer reliability and DX improvements over new features
- Maximum 3 issues
PROMPT_EOF
}

# ─── Call Anthropic API ───────────────────────────────────────────────────────
strategic_call_api() {
    local prompt="$1"

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        error "ANTHROPIC_API_KEY not set — cannot run strategic analysis"
        return 1
    fi

    local tmp_request tmp_response
    tmp_request=$(mktemp)
    tmp_response=$(mktemp)

    # Build request body safely via jq (never string interpolation)
    jq -n --arg prompt "$prompt" --arg model "$STRATEGIC_MODEL" --argjson max_tokens "$STRATEGIC_MAX_TOKENS" '{
        model: $model,
        max_tokens: $max_tokens,
        messages: [{role: "user", content: $prompt}]
    }' > "$tmp_request"

    local http_code
    http_code=$(curl -s -o "$tmp_response" -w '%{http_code}' --max-time 60 \
        -H "x-api-key: ${ANTHROPIC_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "content-type: application/json" \
        -d @"$tmp_request" \
        https://api.anthropic.com/v1/messages 2>/dev/null || echo "000")

    rm -f "$tmp_request"

    if [[ "$http_code" == "200" ]]; then
        local response_text
        response_text=$(jq -r '.content[0].text // empty' "$tmp_response" 2>/dev/null || true)
        rm -f "$tmp_response"

        if [[ -z "$response_text" ]]; then
            error "Anthropic API returned empty response"
            return 1
        fi

        printf '%s' "$response_text"
    else
        error "Anthropic API error (HTTP ${http_code})"
        cat "$tmp_response" 2>/dev/null | head -5 >&2 || true
        rm -f "$tmp_response"
        return 1
    fi
}

# ─── Parse Response & Create Issues ──────────────────────────────────────────
strategic_parse_and_create() {
    local response="$1"
    local created=0
    local skipped=0

    # Split response into issue blocks by "---" delimiter
    local current_title="" current_priority="" current_complexity=""
    local current_strategy="" current_description="" current_acceptance=""
    local in_acceptance=false

    while IFS= read -r line; do
        # Strip carriage returns
        line="${line//$'\r'/}"

        if [[ "$line" == "---" ]] || [[ "$line" == "---"* && ${#line} -le 5 ]]; then
            # End of block — create issue if we have a title
            if [[ -n "$current_title" ]]; then
                strategic_create_issue \
                    "$current_title" "$current_priority" "$current_complexity" \
                    "$current_strategy" "$current_description" "$current_acceptance"
                local rc=$?
                if [[ $rc -eq 0 ]]; then
                    created=$((created + 1))
                else
                    skipped=$((skipped + 1))
                fi

                if [[ "$created" -ge "$STRATEGIC_MAX_ISSUES" ]]; then
                    info "Reached max issues per cycle (${STRATEGIC_MAX_ISSUES})"
                    break
                fi
            fi

            # Reset for next block
            current_title="" current_priority="" current_complexity=""
            current_strategy="" current_description="" current_acceptance=""
            in_acceptance=false
            continue
        fi

        # Parse fields
        if [[ "$line" == ISSUE_TITLE:* ]]; then
            current_title="${line#ISSUE_TITLE: }"
            current_title="${current_title#ISSUE_TITLE:}"
            current_title=$(echo "$current_title" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$line" == PRIORITY:* ]]; then
            current_priority="${line#PRIORITY: }"
            current_priority="${current_priority#PRIORITY:}"
            current_priority=$(echo "$current_priority" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$line" == COMPLEXITY:* ]]; then
            current_complexity="${line#COMPLEXITY: }"
            current_complexity="${current_complexity#COMPLEXITY:}"
            current_complexity=$(echo "$current_complexity" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$line" == STRATEGY_AREA:* ]]; then
            current_strategy="${line#STRATEGY_AREA: }"
            current_strategy="${current_strategy#STRATEGY_AREA:}"
            current_strategy=$(echo "$current_strategy" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$line" == DESCRIPTION:* ]]; then
            current_description="${line#DESCRIPTION: }"
            current_description="${current_description#DESCRIPTION:}"
            current_description=$(echo "$current_description" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$line" == ACCEPTANCE:* ]]; then
            current_acceptance="${line#ACCEPTANCE: }"
            current_acceptance="${current_acceptance#ACCEPTANCE:}"
            current_acceptance=$(echo "$current_acceptance" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=true
        elif [[ "$in_acceptance" == true && "$line" == "- "* ]]; then
            # Continuation of acceptance criteria
            if [[ -n "$current_acceptance" ]]; then
                current_acceptance="${current_acceptance}\n${line}"
            else
                current_acceptance="$line"
            fi
        fi
    done <<< "$response"

    # Handle last block (if no trailing ---)
    if [[ -n "$current_title" && "$created" -lt "$STRATEGIC_MAX_ISSUES" ]]; then
        strategic_create_issue \
            "$current_title" "$current_priority" "$current_complexity" \
            "$current_strategy" "$current_description" "$current_acceptance"
        local rc=$?
        if [[ $rc -eq 0 ]]; then
            created=$((created + 1))
        else
            skipped=$((skipped + 1))
        fi
    fi

    echo "${created}:${skipped}"
}

# ─── Create Single Issue ─────────────────────────────────────────────────────
strategic_create_issue() {
    local title="$1"
    local priority="${2:-P2}"
    local complexity="${3:-standard}"
    local strategy_area="${4:-}"
    local description="${5:-}"
    local acceptance="${6:-}"

    if [[ -z "$title" ]]; then
        return 1
    fi

    # Dry-run mode
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        info "  [dry-run] Would create: ${title}"
        return 0
    fi

    # Dedup: check if an open issue with this exact title already exists
    local existing
    existing=$(gh issue list --state open --search "$title" --json number,title --jq ".[].title" 2>/dev/null || echo "")
    if echo "$existing" | grep -qF "$title" 2>/dev/null; then
        info "  Skipping duplicate: ${title}"
        return 1
    fi

    # Build issue body
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local body
    body=$(cat <<BODY_EOF
## Strategic Improvement

$(echo -e "$description")

### Acceptance Criteria
$(echo -e "$acceptance")

### Context
- **Priority**: ${priority}
- **Complexity**: ${complexity}
- **Generated by**: Strategic Intelligence Agent
- **Strategy alignment**: ${strategy_area}

<!-- STRATEGIC-CYCLE: ${timestamp} -->
BODY_EOF
)

    local labels="auto-patrol,ready-to-build,strategic"

    gh issue create \
        --title "$title" \
        --body "$body" \
        --label "$labels" 2>/dev/null || {
        warn "  Failed to create issue: ${title}"
        return 1
    }

    emit_event "strategic.issue_created" "title=$title" "priority=$priority" "complexity=$complexity"
    success "  Created issue: ${title}"
    return 0
}

# ─── Main Strategic Run ──────────────────────────────────────────────────────
strategic_run() {
    echo -e "\n${PURPLE}${BOLD}━━━ Strategic Intelligence Agent ━━━${RESET}"
    echo -e "${DIM}  Analyzing codebase, strategy, and metrics...${RESET}\n"

    # Check cooldown
    if ! strategic_check_cooldown; then
        return 0
    fi

    # Check API key
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        error "ANTHROPIC_API_KEY not set — strategic analysis requires Anthropic API access"
        return 1
    fi

    # Build prompt with all context
    info "Gathering context..."
    local prompt
    prompt=$(strategic_build_prompt)

    # Call Anthropic API
    info "Calling ${STRATEGIC_MODEL} for strategic analysis..."
    local response
    response=$(strategic_call_api "$prompt") || {
        error "Strategic analysis API call failed"
        emit_event "strategic.cycle_failed" "reason=api_error"
        return 1
    }

    # Parse and create issues
    info "Processing recommendations..."
    local result
    result=$(strategic_parse_and_create "$response")

    local created="${result%%:*}"
    local skipped="${result##*:}"

    # Summary
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Strategic Summary ━━━${RESET}"
    echo -e "  Issues created: ${created}"
    echo -e "  Issues skipped: ${skipped} (duplicates)"
    echo ""

    emit_event "strategic.cycle_complete" "issues_created=$created" "issues_skipped=$skipped"
}

# ─── Status Command ──────────────────────────────────────────────────────────
strategic_status() {
    echo -e "\n${PURPLE}${BOLD}━━━ Strategic Agent Status ━━━${RESET}\n"

    local events_file="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

    if [[ ! -f "$events_file" ]]; then
        info "No events data available"
        return 0
    fi

    # Last run
    local last_run_line
    last_run_line=$(grep '"strategic.cycle_complete"' "$events_file" 2>/dev/null | tail -1 || echo "")

    if [[ -z "$last_run_line" ]]; then
        info "No strategic cycles recorded yet"
        return 0
    fi

    local last_ts last_created last_skipped
    last_ts=$(echo "$last_run_line" | jq -r '.ts // "unknown"' 2>/dev/null || echo "unknown")
    last_created=$(echo "$last_run_line" | jq -r '.issues_created // 0' 2>/dev/null || echo "0")
    last_skipped=$(echo "$last_run_line" | jq -r '.issues_skipped // 0' 2>/dev/null || echo "0")

    echo -e "  Last run:        ${last_ts}"
    echo -e "  Issues created:  ${last_created}"
    echo -e "  Issues skipped:  ${last_skipped}"

    # Cooldown status
    local last_epoch
    last_epoch=$(echo "$last_run_line" | jq -r '.ts_epoch // 0' 2>/dev/null || echo "0")
    local now_e
    now_e=$(now_epoch)
    local elapsed=$(( now_e - last_epoch ))

    if [[ "$elapsed" -lt "$STRATEGIC_COOLDOWN_SECONDS" ]]; then
        local remaining_min=$(( (STRATEGIC_COOLDOWN_SECONDS - elapsed) / 60 ))
        echo -e "  Cooldown:        ${YELLOW}${remaining_min} min remaining${RESET}"
    else
        echo -e "  Cooldown:        ${GREEN}Ready${RESET}"
    fi

    # Total issues created
    local total_created
    total_created=$(grep '"strategic.issue_created"' "$events_file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    echo -e "  Total created:   ${total_created} issues (all time)"

    # Total cycles
    local total_cycles
    total_cycles=$(grep '"strategic.cycle_complete"' "$events_file" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    echo -e "  Total cycles:    ${total_cycles}"

    echo ""
}

# ─── Help ─────────────────────────────────────────────────────────────────────
strategic_show_help() {
    echo -e "${PURPLE}${BOLD}Shipwright Strategic Intelligence Agent${RESET} v${VERSION}\n"
    echo -e "Reads strategy, metrics, and codebase state to create high-impact improvement issues.\n"
    echo -e "${BOLD}Usage:${RESET}"
    echo -e "  sw-strategic.sh <command>\n"
    echo -e "${BOLD}Commands:${RESET}"
    echo -e "  run       Run a strategic analysis cycle"
    echo -e "  status    Show last run stats and cooldown"
    echo -e "  help      Show this help\n"
    echo -e "${BOLD}Environment:${RESET}"
    echo -e "  ANTHROPIC_API_KEY    Required for API calls"
    echo -e "  NO_GITHUB=true       Dry-run mode (no issue creation)\n"
    echo -e "${BOLD}Cooldown:${RESET}"
    echo -e "  12 hours between cycles (checks events.jsonl)\n"
}

# ─── Daemon Integration (sourced mode) ────────────────────────────────────────
strategic_patrol_run() {
    # Called by daemon during patrol cycle
    # Check cooldown (12h minimum between runs)
    # Requires ANTHROPIC_API_KEY
    if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
        echo -e "    ${DIM}●${RESET} Strategic patrol skipped (no ANTHROPIC_API_KEY)"
        return 0
    fi

    if ! strategic_check_cooldown; then
        return 0
    fi

    echo -e "\n  ${BOLD}Strategic Intelligence Patrol${RESET}"
    strategic_run
}

# ─── Source Guard ─────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

    main() {
        local cmd="${1:-help}"
        shift 2>/dev/null || true

        case "$cmd" in
            run)     strategic_run ;;
            status)  strategic_status ;;
            help)    strategic_show_help ;;
            *)
                error "Unknown command: $cmd"
                strategic_show_help
                exit 1
                ;;
        esac
    }

    main "$@"
fi
