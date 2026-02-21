#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright triage — Intelligent Issue Labeling & Prioritization        ║
# ║  Auto-analyze issues, assign labels, score priority, recommend team size ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

VERSION="3.0.0"
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
[[ -z "${CYAN:-}" ]]  && { [[ -z "${NO_COLOR:-}" ]] && CYAN='\033[38;2;0;212;255m'   || CYAN=''; } || true
[[ -z "${RESET:-}" ]] && { [[ -z "${NO_COLOR:-}" ]] && RESET='\033[0m'               || RESET=''; } || true
[[ -z "${BOLD:-}" ]]  && { [[ -z "${NO_COLOR:-}" ]] && BOLD='\033[1m'                || BOLD=''; } || true
[[ -z "${DIM:-}" ]]   && { [[ -z "${NO_COLOR:-}" ]] && DIM='\033[2m'                 || DIM=''; } || true
[[ -z "${GREEN:-}" ]] && { [[ -z "${NO_COLOR:-}" ]] && GREEN='\033[38;2;74;222;128m' || GREEN=''; } || true
[[ -z "${RED:-}" ]]   && { [[ -z "${NO_COLOR:-}" ]] && RED='\033[38;2;248;113;113m'  || RED=''; } || true
[[ -z "${YELLOW:-}" ]] && { [[ -z "${NO_COLOR:-}" ]] && YELLOW='\033[38;2;250;204;21m' || YELLOW=''; } || true
[[ "$(type -t info 2>/dev/null)" == "function" ]]    || info()    { echo -e "\033[38;2;0;212;255m\033[1m▸\033[0m $*"; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo -e "\033[38;2;74;222;128m\033[1m✓\033[0m $*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]]    || warn()    { echo -e "\033[38;2;250;204;21m\033[1m⚠\033[0m $*"; }
[[ "$(type -t error 2>/dev/null)" == "function" ]]   || error()   { echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m $*" >&2; }
if [[ "$(type -t now_iso 2>/dev/null)" != "function" ]]; then
  now_iso()   { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
  now_epoch() { date +%s; }
fi
# ─── GitHub API (safe when NO_GITHUB set) ──────────────────────────────────

check_gh() {
    if [[ "${NO_GITHUB:-}" == "1" ]]; then
        error "GitHub access disabled (NO_GITHUB=1)"
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        error "gh CLI not found. Install: https://cli.github.com"
        exit 1
    fi
}

# ─── Analysis Functions ────────────────────────────────────────────────────

# analyze_type <issue_body>
# Detects issue type from title/body keywords
analyze_type() {
    local body="$1"
    local lower_body
    lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    if echo "$lower_body" | grep -qE "(security|vulnerability|cve|exploit|breach)"; then
        echo "security"
    elif echo "$lower_body" | grep -qE "(performance|speed|latency|slow|optimize|memory)"; then
        echo "performance"
    elif echo "$lower_body" | grep -qE "(bug|broken|crash|error|fail|issue)"; then
        echo "bug"
    elif echo "$lower_body" | grep -qE "(refactor|reorgan|rewrite|clean|improve)"; then
        echo "refactor"
    elif echo "$lower_body" | grep -qE "(doc|guide|readme|tutorial|howto)"; then
        echo "docs"
    elif echo "$lower_body" | grep -qE "(chore|maintain|update|bump|dependencies)"; then
        echo "chore"
    else
        echo "feature"
    fi
}

# analyze_complexity <issue_body>
# Estimates complexity from body length, keywords, mentions
analyze_complexity() {
    local body="$1"
    local score=0

    # Longer issues = more complex (rough heuristic)
    local body_lines
    body_lines=$(echo "$body" | wc -l)
    if [[ $body_lines -gt 50 ]]; then
        score=$((score + 2))
    elif [[ $body_lines -gt 20 ]]; then
        score=$((score + 1))
    fi

    local lower_body
    lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    # Complexity keywords
    if echo "$lower_body" | grep -qE "(epic|major|rewrite|redesign|architecture)"; then
        score=$((score + 3))
    elif echo "$lower_body" | grep -qE "(multiple|several|cascade|dependencies|breaking)"; then
        score=$((score + 2))
    fi

    # Mentions of tests/specs suggest complexity
    if echo "$lower_body" | grep -qE "(test|spec|coverage|validation)"; then
        score=$((score + 1))
    fi

    case $score in
        0) echo "trivial" ;;
        1) echo "simple" ;;
        2|3) echo "moderate" ;;
        4|5) echo "complex" ;;
        *) echo "epic" ;;
    esac
}

# analyze_risk <issue_body>
# Assesses risk from keywords and scope
analyze_risk() {
    local body="$1"
    local score=0
    local lower_body
    lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    if echo "$lower_body" | grep -qE "(security|vulnerability|exploit|critical)"; then
        score=$((score + 3))
    elif echo "$lower_body" | grep -qE "(breaking|migration|deprecat)"; then
        score=$((score + 2))
    elif echo "$lower_body" | grep -qE "(production|staging|database)"; then
        score=$((score + 1))
    fi

    if echo "$lower_body" | grep -qE "(infrastructure|deploy|release)"; then
        score=$((score + 1))
    fi

    case $score in
        0) echo "low" ;;
        1|2) echo "medium" ;;
        3) echo "high" ;;
        *) echo "critical" ;;
    esac
}

# analyze_effort <complexity> <risk>
# Maps complexity+risk → effort estimate
analyze_effort() {
    local complexity="$1"
    local risk="$2"

    case "${complexity}-${risk}" in
        trivial-low) echo "xs" ;;
        trivial-*|simple-low) echo "s" ;;
        simple-medium|moderate-low) echo "m" ;;
        moderate-*|complex-low) echo "l" ;;
        complex-*|epic-*) echo "xl" ;;
        *) echo "m" ;;
    esac
}

# analyze_with_ai <title> <body>
# AI-driven triage via intelligence engine. Returns JSON or empty on failure.
# Schema: {type, complexity, risk, effort, labels[], summary}
# Always falls back to keyword-based analysis when AI unavailable.
analyze_with_ai() {
    local title="$1"
    local body="$2"
    local combined="${title} ${body}"

    # Check sw-intelligence.sh is sourceable and claude CLI exists
    if [[ ! -f "${SCRIPT_DIR}/sw-intelligence.sh" ]]; then
        return 1
    fi
    if ! command -v claude >/dev/null 2>&1; then
        return 1
    fi

    # Source intelligence (provides _intelligence_call_claude, compute_md5)
    if ! source "${SCRIPT_DIR}/sw-intelligence.sh" 2>/dev/null; then
        return 1
    fi

    local prompt
    prompt="Analyze this GitHub issue and return ONLY a valid JSON object (no markdown, no explanation).

Title: ${title}

Body: ${body}

Return JSON with exactly these fields:
{
  \"type\": \"<bug|feature|security|performance|refactor|docs|chore>\",
  \"complexity\": \"<trivial|simple|moderate|complex|epic>\",
  \"risk\": \"<low|medium|high|critical>\",
  \"effort\": \"<xs|s|m|l|xl>\",
  \"labels\": [\"type:X\", \"complexity:X\", \"risk:X\", \"priority:X\", \"effort:X\"],
  \"summary\": \"<brief one-line summary>\"
}"

    local cache_key
    cache_key="triage_analyze_$(compute_md5 --string "$combined" 2>/dev/null || echo "$(echo "$combined" | md5 2>/dev/null | cut -c1-16)")"

    local result
    result=$(_intelligence_call_claude "$prompt" "$cache_key" 2>/dev/null) || true

    if [[ -z "$result" ]] || echo "$result" | jq -e '.' >/dev/null 2>&1; then
        :  # result is empty or valid JSON
    else
        return 1
    fi

    # Validate required fields and normalize
    local type_val complexity_val risk_val effort_val labels_val
    type_val=$(echo "$result" | jq -r '.type // empty' 2>/dev/null)
    complexity_val=$(echo "$result" | jq -r '.complexity // empty' 2>/dev/null)
    risk_val=$(echo "$result" | jq -r '.risk // empty' 2>/dev/null)
    effort_val=$(echo "$result" | jq -r '.effort // empty' 2>/dev/null)
    labels_val=$(echo "$result" | jq -r '.labels // []' 2>/dev/null)

    # Reject if we got an error object
    if echo "$result" | jq -e '.error' >/dev/null 2>&1; then
        return 1
    fi

    # Need at least type or complexity to consider AI result useful
    if [[ -z "$type_val" && -z "$complexity_val" && -z "$risk_val" ]]; then
        return 1
    fi

    # Normalize to valid triage schema values
    local valid_type
    case "$(echo "$type_val" | tr '[:upper:]' '[:lower:]')" in
        bug) valid_type="bug" ;;
        feature) valid_type="feature" ;;
        security) valid_type="security" ;;
        performance) valid_type="performance" ;;
        refactor) valid_type="refactor" ;;
        docs) valid_type="docs" ;;
        chore) valid_type="chore" ;;
        *) valid_type="" ;;
    esac
    local valid_complexity
    case "$(echo "$complexity_val" | tr '[:upper:]' '[:lower:]')" in
        trivial) valid_complexity="trivial" ;;
        simple) valid_complexity="simple" ;;
        moderate) valid_complexity="moderate" ;;
        complex) valid_complexity="complex" ;;
        epic) valid_complexity="epic" ;;
        *) valid_complexity="" ;;
    esac
    local valid_risk
    case "$(echo "$risk_val" | tr '[:upper:]' '[:lower:]')" in
        low) valid_risk="low" ;;
        medium) valid_risk="medium" ;;
        high) valid_risk="high" ;;
        critical) valid_risk="critical" ;;
        *) valid_risk="" ;;
    esac
    local valid_effort
    case "$(echo "$effort_val" | tr '[:upper:]' '[:lower:]')" in
        xs) valid_effort="xs" ;;
        s) valid_effort="s" ;;
        m) valid_effort="m" ;;
        l) valid_effort="l" ;;
        xl) valid_effort="xl" ;;
        *) valid_effort="" ;;
    esac

    jq -n \
        --arg type "${valid_type:-}" \
        --arg complexity "${valid_complexity:-}" \
        --arg risk "${valid_risk:-}" \
        --arg effort "${valid_effort:-}" \
        --argjson labels "${labels_val:-[]}" \
        --arg summary "$(echo "$result" | jq -r '.summary // ""' 2>/dev/null)" \
        '{type: $type, complexity: $complexity, risk: $risk, effort: $effort, labels: $labels, summary: $summary}'
    return 0
}

# suggest_labels <type> <complexity> <risk> <effort>
# Generates label recommendations
suggest_labels() {
    local type="$1"
    local complexity="$2"
    local risk="$3"
    local effort="$4"
    local labels=""

    # Type label
    labels="${labels}type:${type}"

    # Complexity label
    labels="${labels} complexity:${complexity}"

    # Priority label (derived from risk)
    case "$risk" in
        critical) labels="${labels} priority:urgent" ;;
        high) labels="${labels} priority:high" ;;
        medium) labels="${labels} priority:medium" ;;
        *) labels="${labels} priority:low" ;;
    esac

    # Effort label
    labels="${labels} effort:${effort}"

    # Risk label
    labels="${labels} risk:${risk}"

    echo "$labels"
}

# ─── Subcommand: analyze ──────────────────────────────────────────────────

# Check if AI triage should be used (TRIAGE_AI env, --ai flag, or daemon-config)
_triage_use_ai() {
    if [[ "${TRIAGE_AI:-}" == "1" || "${TRIAGE_AI:-}" == "true" ]]; then
        return 0
    fi
    local config="${REPO_DIR}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

cmd_analyze() {
    local issue=""
    local use_ai=false

    # Parse args for --ai and issue number
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ai) use_ai=true; shift ;;
            *) [[ -z "$issue" ]] && issue="$1"; shift ;;
        esac
    done

    [[ -z "$issue" ]] && { error "Usage: triage analyze [--ai] <issue>"; exit 1; }

    # Enable AI if --ai flag or config
    _triage_use_ai && use_ai=true

    check_gh

    info "Analyzing issue ${CYAN}${issue}${RESET}..."

    # Fetch issue via gh CLI
    local issue_json
    issue_json=$(gh issue view "$issue" --json title,body,labels 2>/dev/null || echo "{}")

    if [[ "$issue_json" == "{}" ]]; then
        error "Failed to fetch issue ${CYAN}${issue}${RESET}"
        exit 1
    fi

    local title body existing_labels
    title=$(echo "$issue_json" | jq -r '.title')
    body=$(echo "$issue_json" | jq -r '.body // ""')
    existing_labels=$(echo "$issue_json" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

    local combined_text="${title} ${body}"

    # Keyword-based analysis (always run for fallback)
    local kw_type kw_complexity kw_risk kw_effort kw_labels
    kw_type=$(analyze_type "$combined_text")
    kw_complexity=$(analyze_complexity "$combined_text")
    kw_risk=$(analyze_risk "$combined_text")
    kw_effort=$(analyze_effort "$kw_complexity" "$kw_risk")
    kw_labels=$(suggest_labels "$kw_type" "$kw_complexity" "$kw_risk" "$kw_effort")

    # Try AI analysis first when enabled
    local type="$kw_type" complexity="$kw_complexity" risk="$kw_risk" effort="$kw_effort" labels="$kw_labels"
    if $use_ai; then
        local ai_result
        if ai_result=$(analyze_with_ai "$title" "$body" 2>/dev/null); then
            local ai_type ai_complexity ai_risk ai_effort ai_labels
            ai_type=$(echo "$ai_result" | jq -r '.type // empty')
            ai_complexity=$(echo "$ai_result" | jq -r '.complexity // empty')
            ai_risk=$(echo "$ai_result" | jq -r '.risk // empty')
            ai_effort=$(echo "$ai_result" | jq -r '.effort // empty')
            ai_labels=$(echo "$ai_result" | jq -r '.labels // []' 2>/dev/null)

            # Merge: AI takes precedence where available
            [[ -n "$ai_type" ]] && type="$ai_type"
            [[ -n "$ai_complexity" ]] && complexity="$ai_complexity"
            [[ -n "$ai_risk" ]] && risk="$ai_risk"
            if [[ -n "$ai_effort" ]]; then
                effort="$ai_effort"
            else
                effort=$(analyze_effort "$complexity" "$risk")
            fi
            if [[ -n "$ai_labels" && "$ai_labels" != "[]" ]]; then
                labels=$(echo "$ai_labels" | jq -r 'join(" ")')
            else
                labels=$(suggest_labels "$type" "$complexity" "$risk" "$effort")
            fi
            info "AI triage applied"
        else
            warn "AI triage unavailable, using keyword analysis"
        fi
    fi

    # Output as structured JSON
    cat << EOF
{
  "issue": "$issue",
  "title": $(jq -R . <<< "$title"),
  "type": "$type",
  "complexity": "$complexity",
  "risk": "$risk",
  "effort": "$effort",
  "suggested_labels": $(echo "$labels" | jq -R 'split(" ")'),
  "existing_labels": $(echo "$existing_labels" | jq -R 'split(",")')
}
EOF

    emit_event "triage_analyzed" "issue=$issue" "type=$type" "complexity=$complexity" "risk=$risk"
}

# ─── Subcommand: label ────────────────────────────────────────────────────

cmd_label() {
    local issue="${1:-}"
    [[ -z "$issue" ]] && { error "Usage: triage label <issue>"; exit 1; }

    check_gh

    info "Labeling issue ${CYAN}${issue}${RESET}..."

    # Get suggested labels
    local analysis
    analysis=$(cmd_analyze "$issue" 2>/dev/null)

    local labels_str
    labels_str=$(echo "$analysis" | jq -r '.suggested_labels | join(" ")')

    # Apply labels via gh CLI
    local label_array=()
    while IFS= read -r _l; do [[ -n "$_l" ]] && label_array+=("$_l"); done <<< "$(echo "$labels_str" | tr ' ' '\n')"

    for label in "${label_array[@]}"; do
        [[ -z "$label" ]] && continue
        gh label create "$label" --repo "$(gh repo view --json nameWithOwner -q)" 2>/dev/null || true
        gh issue edit "$issue" --add-label "$label" 2>/dev/null || true
        success "Applied label: ${CYAN}${label}${RESET}"
    done

    emit_event "triage_labeled" "issue=$issue" "label_count=${#label_array[@]}"
}

# ─── Subcommand: prioritize ───────────────────────────────────────────────

cmd_prioritize() {
    check_gh

    info "Scoring open issues..."

    local output_json="[]"

    # Fetch all open issues
    local issues_json
    issues_json=$(gh issue list --state open --json number,title,body,labels,createdAt,reactions --limit "$(_config_get_int "limits.triage_issues" 100)" 2>/dev/null || echo "[]")

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length')
    info "Found ${CYAN}${issue_count}${RESET} open issues"

    # Score each issue
    while IFS= read -r issue_json; do
        local number title body labels
        number=$(echo "$issue_json" | jq -r '.number')
        title=$(echo "$issue_json" | jq -r '.title')
        body=$(echo "$issue_json" | jq -r '.body // ""')
        labels=$(echo "$issue_json" | jq -r '.labels[].name' | tr '\n' ',' | sed 's/,$//')

        local combined="${title} ${body}"
        local type complexity risk
        type=$(analyze_type "$combined")
        complexity=$(analyze_complexity "$combined")
        risk=$(analyze_risk "$combined")

        # Score calculation: (Impact × 3) + (Urgency × 2) − (Effort × 0.5)
        # Impact: risk level (0-3)
        # Urgency: 1 if labeled urgent/blocking, else 0.5
        # Effort: trivial=1, simple=2, moderate=3, complex=4, epic=5
        local impact urgency effort_score
        case "$risk" in
            critical) impact=3 ;;
            high) impact=2 ;;
            medium) impact=1 ;;
            *) impact=0 ;;
        esac

        if echo "$labels" | grep -qE "(urgent|blocking|critical)"; then
            urgency=1
        else
            urgency=0.5
        fi

        case "$complexity" in
            trivial) effort_score=1 ;;
            simple) effort_score=2 ;;
            moderate) effort_score=3 ;;
            complex) effort_score=4 ;;
            epic) effort_score=5 ;;
            *) effort_score=3 ;;
        esac

        local score
        score=$(awk "BEGIN {printf \"%.1f\", ($impact * 3) + ($urgency * 2) - ($effort_score * 0.5)}")

        local item
        item=$(jq -n \
            --arg number "$number" \
            --arg title "$title" \
            --arg type "$type" \
            --arg complexity "$complexity" \
            --arg risk "$risk" \
            --arg score "$score" \
            '{number: $number, title: $title, type: $type, complexity: $complexity, risk: $risk, score: ($score | tonumber)}')

        output_json=$(echo "$output_json" | jq ". += [$item]")
    done < <(echo "$issues_json" | jq -c '.[]')

    # Sort by score descending
    output_json=$(echo "$output_json" | jq 'sort_by(.score) | reverse')

    # Pretty print
    echo ""
    echo -e "${BOLD}Prioritized Backlog${RESET}"
    echo "─────────────────────────────────────────────────────────────────"
    echo ""
    echo "$output_json" | jq -r '.[] | "#\(.number) \(.score): \(.title) [type:\(.type) complexity:\(.complexity) risk:\(.risk)]"' | while IFS= read -r line; do
        local number score rest
        number=$(echo "$line" | cut -d' ' -f1)
        score=$(echo "$line" | cut -d' ' -f2 | tr -d ':')
        rest=$(echo "$line" | cut -d' ' -f3-)

        echo -e "  ${CYAN}${number}${RESET} ${BOLD}${score}${RESET}  ${rest}"
    done

    echo ""
    info "Output: $(echo "$output_json" | jq 'length') issues ranked"

    emit_event "triage_prioritized" "issue_count=$(echo "$output_json" | jq 'length')"
}

# ─── Subcommand: team ─────────────────────────────────────────────────────

cmd_team() {
    local issue="${1:-}"
    [[ -z "$issue" ]] && { error "Usage: triage team <issue>"; exit 1; }

    info "Recommending team setup for issue ${CYAN}${issue}${RESET}..."

    # Determine if GitHub is available (don't exit — allow offline fallback)
    local gh_available=false
    if [[ "${NO_GITHUB:-}" != "1" ]] && command -v gh >/dev/null 2>&1; then
        gh_available=true
    fi

    # Get analysis (requires gh) — use defaults when offline
    local analysis="" complexity="moderate" risk="medium" effort="m"
    if $gh_available; then
        analysis=$(cmd_analyze "$issue" 2>/dev/null) || true
        if [[ -n "$analysis" ]]; then
            complexity=$(echo "$analysis" | jq -r '.complexity // "moderate"')
            risk=$(echo "$analysis" | jq -r '.risk // "medium"')
            effort=$(echo "$analysis" | jq -r '.effort // "m"')
        fi
    else
        warn "GitHub unavailable — using defaults for complexity/risk analysis"
    fi

    # ── Try recruit-powered team composition first ──
    local template="" model="" max_iterations="" agents=""
    local recruit_source="heuristic"
    if [[ -x "${SCRIPT_DIR:-}/sw-recruit.sh" ]]; then
        local issue_title=""
        # Try to get title from GitHub; fall back to issue number as description
        if $gh_available; then
            issue_title=$(gh issue view "$issue" --json title -q '.title' 2>/dev/null || echo "")
        fi
        [[ -z "$issue_title" ]] && issue_title="Issue #${issue}"

        local recruit_result
        recruit_result=$(bash "$SCRIPT_DIR/sw-recruit.sh" team --json "$issue_title" 2>/dev/null) || true
        if [[ -n "$recruit_result" ]] && echo "$recruit_result" | jq -e '.team' >/dev/null 2>&1; then
            model=$(echo "$recruit_result" | jq -r '.model // "sonnet"')
            agents=$(echo "$recruit_result" | jq -r '.agents // 2')
            template=$(echo "$recruit_result" | jq -r '.template // ""')
            max_iterations=$(echo "$recruit_result" | jq -r '.max_iterations // ""')
            # If recruit didn't provide template/max_iterations, derive from agent count
            if [[ -z "$template" ]]; then
                if [[ "$agents" -ge 4 ]]; then template="full"; max_iterations="${max_iterations:-15}";
                elif [[ "$agents" -ge 3 ]]; then template="standard"; max_iterations="${max_iterations:-8}";
                elif [[ "$agents" -le 1 ]]; then template="fast"; max_iterations="${max_iterations:-2}";
                else template="standard"; max_iterations="${max_iterations:-5}"; fi
            fi
            recruit_source="recruit"
        fi
    fi

    # ── Fallback: hardcoded complexity/risk mapping ──
    if [[ -z "$template" ]]; then
        case "${complexity}-${risk}" in
            trivial-low|simple-low)
                template="fast"
                model="haiku"
                max_iterations=2
                agents=1
                ;;
            simple-*|moderate-low)
                template="standard"
                model="sonnet"
                max_iterations=5
                agents=2
                ;;
            moderate-*|complex-low)
                template="standard"
                model="sonnet"
                max_iterations=8
                agents=3
                ;;
            complex-*|epic-*)
                template="full"
                model="opus"
                max_iterations=15
                agents=4
                ;;
            *)
                template="standard"
                model="sonnet"
                max_iterations=5
                agents=2
                ;;
        esac
    fi

    cat << EOF
{
  "issue": "$issue",
  "complexity": "$complexity",
  "risk": "$risk",
  "effort": "$effort",
  "recommendation": {
    "pipeline_template": "$template",
    "model": "$model",
    "max_iterations": $max_iterations,
    "agents": $agents,
    "source": "$recruit_source"
  }
}
EOF

    emit_event "triage_team_recommended" "issue=$issue" "template=$template" "agents=$agents" "source=$recruit_source"
}

# ─── Subcommand: batch ────────────────────────────────────────────────────

cmd_batch() {
    check_gh

    info "Batch analyzing and labeling unlabeled open issues..."

    # Fetch unlabeled open issues
    local issues_json
    issues_json=$(gh issue list --state open --search "no:label" --json number --limit "$(_config_get_int "limits.triage_unlabeled" 50)" 2>/dev/null || echo "[]")

    local issue_count
    issue_count=$(echo "$issues_json" | jq 'length')
    info "Found ${CYAN}${issue_count}${RESET} unlabeled issues"

    local success_count=0
    echo "$issues_json" | jq -r '.[] | .number' | while IFS= read -r number; do
        if cmd_label "$number" >/dev/null 2>&1; then
            success_count=$((success_count + 1))
        fi
    done

    success "Labeled ${CYAN}${issue_count}${RESET} issues"
    emit_event "triage_batch_complete" "issue_count=$issue_count"
}

# ─── Subcommand: report ───────────────────────────────────────────────────

cmd_report() {
    check_gh

    info "Generating triage statistics..."

    # Fetch labeled issues
    local issues_json
    issues_json=$(gh issue list --state open --json labels,title,number --limit "$(_config_get_int "limits.triage_issues" 100)" 2>/dev/null || echo "[]")

    local type_counts complexity_counts priority_counts
    type_counts='{}'
    complexity_counts='{}'
    priority_counts='{}'

    echo "$issues_json" | jq -c '.[]' | while IFS= read -r issue_json; do
        local labels
        labels=$(echo "$issue_json" | jq -r '.labels[].name' | tr '\n' ',')

        # Extract type
        local type
        type=$(echo "$labels" | grep -oE "type:[a-z-]+" | cut -d: -f2 | head -1 || echo "unknown")
        type_counts=$(echo "$type_counts" | jq --arg t "$type" '.[$t] = (.[$t] // 0) + 1')

        # Extract complexity
        local complexity
        complexity=$(echo "$labels" | grep -oE "complexity:[a-z-]+" | cut -d: -f2 | head -1 || echo "unknown")
        complexity_counts=$(echo "$complexity_counts" | jq --arg c "$complexity" '.[$c] = (.[$c] // 0) + 1')

        # Extract priority
        local priority
        priority=$(echo "$labels" | grep -oE "priority:[a-z-]+" | cut -d: -f2 | head -1 || echo "unknown")
        priority_counts=$(echo "$priority_counts" | jq --arg p "$priority" '.[$p] = (.[$p] // 0) + 1')
    done

    # Output report
    echo ""
    echo -e "${BOLD}Triage Report${RESET}"
    echo "─────────────────────────────────────────────────────────────────"
    echo ""
    echo -e "${BOLD}By Type:${RESET}"
    echo "$type_counts" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
    echo ""
    echo -e "${BOLD}By Complexity:${RESET}"
    echo "$complexity_counts" | jq -r 'to_entries[] | "  \(.key): \(.value)"'
    echo ""
    echo -e "${BOLD}By Priority:${RESET}"
    echo "$priority_counts" | jq -r 'to_entries[] | "  \(.key): \(.value)"'

    emit_event "triage_report_generated"
}

# ─── Subcommand: help ────────────────────────────────────────────────────

cmd_help() {
    echo -e "${BOLD}shipwright triage${RESET} — Intelligent Issue Labeling & Prioritization"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  ${CYAN}shipwright triage${RESET} <subcommand> [options]"
    echo ""
    echo -e "${BOLD}SUBCOMMANDS${RESET}"
    echo -e "  ${CYAN}analyze [--ai] <issue>${RESET}  Analyze issue and suggest labels (outputs JSON)"
    echo -e "  ${CYAN}label <issue>${RESET}          Apply suggested labels to issue"
    echo -e "  ${CYAN}prioritize${RESET}            Score and rank all open issues by priority"
    echo -e "  ${CYAN}team <issue>${RESET}           Recommend team size & pipeline template"
    echo -e "  ${CYAN}batch${RESET}                  Analyze + label all unlabeled open issues"
    echo -e "  ${CYAN}report${RESET}                 Show triage statistics (type, complexity, priority)"
    echo -e "  ${CYAN}help${RESET}                   Show this help message"
    echo ""
    echo -e "${BOLD}EXAMPLES${RESET}"
    echo -e "  ${DIM}shipwright triage analyze 42${RESET}"
    echo -e "  ${DIM}shipwright triage analyze --ai 42${RESET}"
    echo -e "  ${DIM}shipwright triage --ai analyze 42${RESET}"
    echo -e "  ${DIM}shipwright triage label 42${RESET}"
    echo -e "  ${DIM}shipwright triage prioritize${RESET}"
    echo -e "  ${DIM}shipwright triage team 42${RESET}"
    echo -e "  ${DIM}shipwright triage batch${RESET}"
    echo -e "  ${DIM}shipwright triage report${RESET}"
    echo ""
}

# ─── Main ──────────────────────────────────────────────────────────────────

main() {
    # Parse global --ai flag (enables AI triage for this invocation)
    if [[ "${1:-}" == "--ai" ]]; then
        export TRIAGE_AI=1
        shift
    fi

    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        analyze)
            cmd_analyze "$@"
            ;;
        label)
            cmd_label "$@"
            ;;
        prioritize)
            cmd_prioritize "$@"
            ;;
        team)
            cmd_team "$@"
            ;;
        batch)
            cmd_batch "$@"
            ;;
        report)
            cmd_report "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            error "Unknown subcommand: ${cmd}"
            cmd_help
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
