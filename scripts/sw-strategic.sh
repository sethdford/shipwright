#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-strategic.sh — Strategic Intelligence Agent                         ║
# ║  Reads strategy, metrics, and codebase to create high-impact issues     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# This file can be BOTH sourced (by sw-daemon.sh) and run standalone.
# When sourced, do NOT add set -euo pipefail — the parent handles that.
# When run directly, main() sets up the error handling.

VERSION="2.2.0"

# ─── Paths (set defaults if not provided by parent) ──────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
EVENTS_FILE="${EVENTS_FILE:-${HOME}/.shipwright/events.jsonl}"

# Canonical helpers (colors, output, events)
# shellcheck source=lib/helpers.sh
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh"
# Fallbacks when helpers not loaded (e.g. test env, sourced by daemon)
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t emit_event 2>/dev/null)" != "function" ]]; then
  emit_event() {
    local event_type="$1"; shift; mkdir -p "${HOME}/.shipwright"
    local payload="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"$event_type\""
    while [[ $# -gt 0 ]]; do local key="${1%%=*}" val="${1#*=}"; payload="${payload},\"${key}\":\"${val}\""; shift; done
    echo "${payload}}" >> "${HOME}/.shipwright/events.jsonl"
  }
fi
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
CYAN="${CYAN:-\033[38;2;0;212;255m}"
PURPLE="${PURPLE:-\033[38;2;124;58;237m}"
GREEN="${GREEN:-\033[38;2;74;222;128m}"
YELLOW="${YELLOW:-\033[38;2;250;204;21m}"
RED="${RED:-\033[38;2;248;113;113m}"
DIM="${DIM:-\033[2m}"
BOLD="${BOLD:-\033[1m}"
RESET="${RESET:-\033[0m}"

# ─── Constants (policy overrides when config/policy.json exists) ─────────────
STRATEGIC_MAX_ISSUES=5
STRATEGIC_COOLDOWN_SECONDS=14400  # 4 hours
STRATEGIC_MODEL="claude-sonnet-4-5-20250929"
STRATEGIC_MAX_TOKENS=4096
STRATEGIC_STRATEGY_LINES=200
STRATEGIC_LABELS="auto-patrol,ready-to-build,strategic,shipwright"
STRATEGIC_OVERLAP_THRESHOLD=60  # Skip if >60% word overlap
[[ -f "${SCRIPT_DIR:-}/lib/policy.sh" ]] && source "${SCRIPT_DIR:-}/lib/policy.sh"
if type policy_get &>/dev/null 2>&1; then
    STRATEGIC_MAX_ISSUES=$(policy_get ".strategic.max_issues_per_cycle" "5")
    STRATEGIC_COOLDOWN_SECONDS=$(policy_get ".strategic.cooldown_seconds" "14400")
    STRATEGIC_STRATEGY_LINES=$(policy_get ".strategic.strategy_lines" "200")
    STRATEGIC_OVERLAP_THRESHOLD=$(policy_get ".strategic.overlap_threshold_percent" "60")
fi

# ─── Semantic Dedup ─────────────────────────────────────────────────────────
# Cache of existing issue titles (open + recently closed) loaded at cycle start.
STRATEGIC_TITLE_CACHE=""

# Compute word-overlap similarity between two titles (0-100).
# Uses lowercase word sets, ignoring common stop words.
strategic_word_overlap() {
    local title_a="$1"
    local title_b="$2"

    # Normalize: lowercase, strip punctuation, split to words, basic stemming
    local words_a words_b
    words_a=$(printf '%s' "$title_a" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | \
        sed -E 's/ations?$//; s/tions?$//; s/ments?$//; s/ings?$//; s/ness$//; s/ies$/y/; s/([^s])s$/\1/' | \
        sort -u | grep -vE '^(a|an|the|and|or|for|to|in|of|is|it|by|on|at|with|from|based)$' | grep -v '^$' || true)
    words_b=$(printf '%s' "$title_b" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' | \
        sed -E 's/ations?$//; s/tions?$//; s/ments?$//; s/ings?$//; s/ness$//; s/ies$/y/; s/([^s])s$/\1/' | \
        sort -u | grep -vE '^(a|an|the|and|or|for|to|in|of|is|it|by|on|at|with|from|based)$' | grep -v '^$' || true)

    [[ -z "$words_a" || -z "$words_b" ]] && echo "0" && return 0

    # Count words in each set
    local count_a count_b
    count_a=$(printf '%s\n' "$words_a" | wc -l | tr -d ' ')
    count_b=$(printf '%s\n' "$words_b" | wc -l | tr -d ' ')

    # Count shared words (intersection)
    local shared
    shared=$(comm -12 <(printf '%s\n' "$words_a") <(printf '%s\n' "$words_b") | wc -l | tr -d ' ')

    # Overlap = shared / min(count_a, count_b) * 100
    local min_count
    if [[ "$count_a" -le "$count_b" ]]; then
        min_count="$count_a"
    else
        min_count="$count_b"
    fi

    [[ "$min_count" -eq 0 ]] && echo "0" && return 0

    echo $(( shared * 100 / min_count ))
}

# Load all open + recently closed issue titles into cache.
strategic_load_title_cache() {
    STRATEGIC_TITLE_CACHE=""

    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        return 0
    fi

    local open_titles closed_titles
    open_titles=$(gh issue list --state open --json title --jq '.[].title' 2>/dev/null || echo "")
    closed_titles=$(gh issue list --state closed --limit 30 --json title --jq '.[].title' 2>/dev/null || echo "")

    STRATEGIC_TITLE_CACHE="${open_titles}
${closed_titles}"
}

# Check if a title has >threshold% overlap with any cached title.
# Returns 0 (true) if a near-duplicate is found, 1 (false) otherwise.
strategic_is_near_duplicate() {
    local new_title="$1"

    [[ -z "$STRATEGIC_TITLE_CACHE" ]] && return 1

    while IFS= read -r existing_title; do
        [[ -z "$existing_title" ]] && continue
        local overlap
        overlap=$(strategic_word_overlap "$new_title" "$existing_title")
        if [[ "$overlap" -gt "$STRATEGIC_OVERLAP_THRESHOLD" ]]; then
            info "  Near-duplicate (${overlap}% overlap): \"${existing_title}\"" >&2
            return 0
        fi
    done <<< "$STRATEGIC_TITLE_CACHE"

    return 1
}

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

    # Recently closed issues (last 20) — so we don't rebuild what was just shipped
    local recent_closed=""
    if [[ "${NO_GITHUB:-false}" != "true" ]]; then
        recent_closed=$(gh issue list --state closed --limit 20 --json number,title --jq '.[] | "#\(.number): \(.title)"' 2>/dev/null || echo "(could not fetch)")
    else
        recent_closed="(GitHub access disabled)"
    fi

    # Platform health (hygiene + platform-refactor scan) — for AGI-level self-improvement
    local platform_health_section="(No platform hygiene data — run \`shipwright hygiene platform-refactor\` or \`shipwright hygiene scan\` to generate .claude/platform-hygiene.json)"
    if [[ -f "${repo_dir}/.claude/platform-hygiene.json" ]]; then
        local ph_summary
        ph_summary=$(jq -r '
            "Counts: hardcoded=\(.counts.hardcoded // 0), fallback=\(.counts.fallback // 0), TODO=\(.counts.todo // 0), FIXME=\(.counts.fixme // 0), HACK/KLUDGE=\(.counts.hack // 0). " +
            "Largest scripts (lines): " + ((.script_size_hotspots // [] | .[0:5] | map("\(.script):\(.lines)") | join(", ")) // "none") + ". " +
            "Sample findings: " + (((.findings_sample // [] | length) | tostring) + " file:line entries.")
        ' "${repo_dir}/.claude/platform-hygiene.json" 2>/dev/null || echo "")
        if [[ -n "$ph_summary" ]]; then
            platform_health_section="Platform refactor scan (AGI-level self-improvement): $ph_summary Use this to suggest refactor, reduce-hardcoding, or clean-architecture issues when it would move the platform toward full autonomy."
        fi
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

## Recently Completed (already built — do NOT recreate these)
${recent_closed}

## Platform Health (refactor / hardcoded / AGI-level readiness)
${platform_health_section}

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
- Do NOT duplicate any open issue OR any recently completed issue
- Prioritize based on STRATEGY.md priorities (P0 > P1 > P2 > ...)
- Focus on concrete, actionable improvements (not vague goals)
- Each issue should be completable by one autonomous pipeline run
- Balance: reliability/DX fixes AND strategic new capabilities
- Think about what would make the biggest impact on success rate, developer experience, and system intelligence
- Be ambitious — push the platform forward, don't just maintain it
- AGI-level criterion: Consider what's hardcoded, static, or not clean architecture. When platform health data supports it, one of your recommendations MAY be a platform refactor or hygiene/architecture improvement (e.g. reduce hardcoded policy, move tunables to config, split monolithic scripts) so the platform can improve itself.
- Maximum ${STRATEGIC_MAX_ISSUES} issues
PROMPT_EOF
}

# ─── Call Anthropic API ───────────────────────────────────────────────────────
strategic_call_api() {
    local prompt="$1"

    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        error "CLAUDE_CODE_OAUTH_TOKEN not set — cannot run strategic analysis"
        return 1
    fi

    if ! command -v claude &>/dev/null; then
        error "Claude Code CLI not found — install with: npm install -g @anthropic-ai/claude-code"
        return 1
    fi

    local tmp_prompt
    tmp_prompt=$(mktemp)
    printf '%s' "$prompt" > "$tmp_prompt"

    local response_text
    response_text=$(cat "$tmp_prompt" | claude -p --max-turns 1 --model "$STRATEGIC_MODEL" 2>/dev/null || echo "")
    rm -f "$tmp_prompt"

    if [[ -z "$response_text" ]]; then
        error "Claude returned empty response"
        return 1
    fi

    # Strip markdown code fences if present (Sonnet sometimes wraps output)
    response_text=$(printf '%s' "$response_text" | sed '/^```/d')

    # Debug: show first 200 chars of response
    local preview
    preview=$(printf '%s' "$response_text" | head -c 200)
    info "Response preview: ${preview}..." >&2

    printf '%s' "$response_text"
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
                    info "Reached max issues per cycle (${STRATEGIC_MAX_ISSUES})" >&2
                    break
                fi
            fi

            # Reset for next block
            current_title="" current_priority="" current_complexity=""
            current_strategy="" current_description="" current_acceptance=""
            in_acceptance=false
            continue
        fi

        # Strip leading markdown bold/italic markers for field matching
        local clean_line
        clean_line=$(echo "$line" | sed 's/^\*\*//;s/\*\*$//' | sed 's/^__//;s/__$//' | sed 's/^[[:space:]]*//')

        # Parse fields (match with and without markdown formatting)
        if [[ "$clean_line" == ISSUE_TITLE:* ]]; then
            current_title="${clean_line#ISSUE_TITLE: }"
            current_title="${current_title#ISSUE_TITLE:}"
            current_title=$(echo "$current_title" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$clean_line" == PRIORITY:* ]]; then
            current_priority="${clean_line#PRIORITY: }"
            current_priority="${current_priority#PRIORITY:}"
            current_priority=$(echo "$current_priority" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$clean_line" == COMPLEXITY:* ]]; then
            current_complexity="${clean_line#COMPLEXITY: }"
            current_complexity="${current_complexity#COMPLEXITY:}"
            current_complexity=$(echo "$current_complexity" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$clean_line" == STRATEGY_AREA:* ]]; then
            current_strategy="${clean_line#STRATEGY_AREA: }"
            current_strategy="${current_strategy#STRATEGY_AREA:}"
            current_strategy=$(echo "$current_strategy" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$clean_line" == DESCRIPTION:* ]]; then
            current_description="${clean_line#DESCRIPTION: }"
            current_description="${current_description#DESCRIPTION:}"
            current_description=$(echo "$current_description" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            in_acceptance=false
        elif [[ "$clean_line" == ACCEPTANCE:* ]]; then
            current_acceptance="${clean_line#ACCEPTANCE: }"
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

    # Semantic dedup: check word overlap against cached titles
    if strategic_is_near_duplicate "$title"; then
        info "  Skipping near-duplicate: ${title}" >&2
        return 1
    fi

    # Dry-run mode
    if [[ "${NO_GITHUB:-false}" == "true" ]]; then
        info "  [dry-run] Would create: ${title}" >&2
        return 0
    fi

    # Dedup: check if an open issue with this exact title already exists
    local existing
    existing=$(gh issue list --state open --search "$title" --json number,title --jq ".[].title" 2>/dev/null || echo "")
    if echo "$existing" | grep -qF "$title" 2>/dev/null; then
        info "  Skipping duplicate: ${title}" >&2
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

    local labels="${STRATEGIC_LABELS}"

    # Ensure all labels exist (create if missing)
    local IFS=','
    for lbl in $labels; do
        gh label create "$lbl" --color "7c3aed" 2>/dev/null || true
    done
    unset IFS

    local issue_url
    issue_url=$(gh issue create \
        --title "$title" \
        --body "$body" \
        --label "$labels" 2>/dev/null) || {
        warn "  Failed to create issue: ${title}" >&2
        return 1
    }

    emit_event "strategic.issue_created" "title=$title" "priority=$priority" "complexity=$complexity"
    # Add to title cache so subsequent issues in this cycle don't duplicate
    STRATEGIC_TITLE_CACHE="${STRATEGIC_TITLE_CACHE}
${title}"
    # Output to stderr so it doesn't pollute the parse_and_create return value
    success "  Created issue: ${title} (${issue_url})" >&2
    return 0
}

# ─── Main Strategic Run ──────────────────────────────────────────────────────
strategic_run() {
    local force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) shift ;;
        esac
    done

    echo -e "\n${PURPLE}${BOLD}━━━ Strategic Intelligence Agent ━━━${RESET}"
    echo -e "${DIM}  Analyzing codebase, strategy, and metrics...${RESET}\n"

    # Check cooldown (skip if --force)
    if [[ "$force" != true ]]; then
        if ! strategic_check_cooldown; then
            return 0
        fi
    else
        info "Cooldown bypassed (--force)"
    fi

    # Check auth token
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        error "CLAUDE_CODE_OAUTH_TOKEN not set — strategic analysis requires Claude access"
        return 1
    fi

    # Load existing issue titles for semantic dedup
    info "Loading issue title cache for dedup..."
    strategic_load_title_cache

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

    # Only record cycle completion if we actually ran analysis (for cooldown tracking)
    # This prevents a "0 issues" run from burning the cooldown timer
    if [[ "$created" -gt 0 ]] || [[ "$skipped" -gt 0 ]]; then
        emit_event "strategic.cycle_complete" "issues_created=$created" "issues_skipped=$skipped"
    else
        info "No issues produced — cooldown NOT reset (will retry next cycle)"
    fi
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
    echo -e "  run [--force]  Run a strategic analysis cycle (--force bypasses cooldown)"
    echo -e "  status         Show last run stats and cooldown"
    echo -e "  help           Show this help\n"
    echo -e "${BOLD}Environment:${RESET}"
    echo -e "  CLAUDE_CODE_OAUTH_TOKEN  Required for Claude access"
    echo -e "  NO_GITHUB=true           Dry-run mode (no issue creation)\n"
    echo -e "${BOLD}Configuration:${RESET}"
    echo -e "  Max issues/cycle:  ${STRATEGIC_MAX_ISSUES}"
    echo -e "  Cooldown:          $(( STRATEGIC_COOLDOWN_SECONDS / 3600 )) hours"
    echo -e "  Model:             ${STRATEGIC_MODEL}\n"
}

# ─── Daemon Integration (sourced mode) ────────────────────────────────────────
strategic_patrol_run() {
    # Called by daemon during patrol cycle
    # Check cooldown (12h minimum between runs)
    # Requires CLAUDE_CODE_OAUTH_TOKEN
    if [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        echo -e "    ${DIM}●${RESET} Strategic patrol skipped (no CLAUDE_CODE_OAUTH_TOKEN)"
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
            run)     strategic_run "$@" ;;
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
