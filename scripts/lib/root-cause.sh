#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  root-cause — Failure Root Cause Classification & Platform Issue Auto-Create
# ║
# ║  Categorizes pipeline failures into systematic root cause types:
# ║  - code_bug: User code problems (test failures, syntax errors)
# ║  - infra_issue: Infrastructure problems (timeouts, disk, network)
# ║  - rate_limit: API rate limiting (Claude, GitHub)
# ║  - context_exhaustion: Claude context window exceeded
# ║  - flatline: Build loop stopped changing code and repeated the same error
# ║  - platform_bug: Shipwright script errors, missing functions
# ║  - config_error: Invalid pipeline/environment configuration
# ║  - external_dep: Dependency failures (npm, pip, cargo, etc.)
# ║
# ║  Auto-creates GitHub issues for platform bugs (confidence >70%)
# ║  Records classification patterns for learning
# ║  Provides automated fix suggestions and MTTR analytics
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="3.3.0"

# Module guard
[[ -n "${_ROOT_CAUSE_LOADED:-}" ]] && return 0; _ROOT_CAUSE_LOADED=1

# ─── Defaults ──────────────────────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.claude}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$STATE_DIR/pipeline-artifacts}"
NO_GITHUB="${NO_GITHUB:-}"

# Ensure helpers are loaded
[[ -f "$SCRIPT_DIR/lib/helpers.sh" ]] && source "$SCRIPT_DIR/lib/helpers.sh" 2>/dev/null || true
[[ "$(type -t info 2>/dev/null)" == "function" ]] || info() { echo "$*"; }
[[ "$(type -t warn 2>/dev/null)" == "function" ]] || warn() { echo "$*" >&2; }
[[ "$(type -t error 2>/dev/null)" == "function" ]] || error() { echo "$*" >&2; }
[[ "$(type -t success 2>/dev/null)" == "function" ]] || success() { echo "$*"; }
[[ "$(type -t emit_event 2>/dev/null)" == "function" ]] || emit_event() { true; }

# ═══════════════════════════════════════════════════════════════════════════════
# Classify a failure into root cause categories
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_classify() {
    local error_message="${1:-}"
    local stage="${2:-unknown}"
    local exit_code="${3:-1}"

    [[ -z "$error_message" ]] && { echo '{"category":"unknown","confidence":0,"evidence":[],"suggested_action":"Review error logs"}'; return 0; }

    local category="unknown"
    local confidence=0
    local evidence=()

    # ─── Rate Limit Detection ───────────────────────────────────────────────────
    if echo "$error_message" | grep -qiE '(rate limit|429|too many requests|throttled|limited|quota|backoff)'; then
        category="rate_limit"
        confidence=95
        evidence+=("Explicit rate limit message detected")
        [[ "$error_message" =~ claude ]] && evidence+=("Claude API rate limit")
        [[ "$error_message" =~ github ]] && evidence+=("GitHub API rate limit")
    # ─── Flatline (no code change, same error — not context exhaustion) ────────
    elif echo "$error_message" | grep -qiE '(flatline|flatlined|no code change.*same error|same error.*no code change)'; then
        category="flatline"
        confidence=85
        evidence+=("Build loop flatlined: iterations repeated the same error without changing code")
    # ─── Context Exhaustion ──────────────────────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(context window|context.*exceed|token.*limit|auto-compact|maximum context|context.*exhaust)'; then
        category="context_exhaustion"
        confidence=90
        evidence+=("Context window exhaustion detected")
    # ─── Infrastructure Issues ───────────────────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(timeout|timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|network|socket hang|OOM|out of memory|killed|signal 9|cannot allocate|disk full|no space|ENOMEM|ENOSPC)'; then
        category="infra_issue"
        confidence=85
        evidence+=("Infrastructure problem detected")
        [[ "$error_message" =~ timeout ]] && evidence+=("Timeout detected")
        [[ "$error_message" =~ OOM|memory ]] && evidence+=("Memory exhaustion")
        [[ "$error_message" =~ disk|space ]] && evidence+=("Disk space issue")
        [[ "$error_message" =~ network|socket ]] && evidence+=("Network issue")
    # ─── Platform Bugs (Shipwright errors) ──────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(sw-.*\.sh|shipwright|unbound variable|command not found.*sw-|pipeline-state|unexpected end)'; then
        category="platform_bug"
        confidence=80
        evidence+=("Shipwright platform error detected")
        [[ "$error_message" =~ unbound ]] && evidence+=("Unbound variable in Shipwright code")
        [[ "$error_message" =~ "command not found" ]] && evidence+=("Missing Shipwright function or script")
    # ─── Configuration Errors ───────────────────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(missing.*config|invalid.*json|PIPELINE_CONFIG|no such template|bad config|invalid.*template|unknown.*option)'; then
        category="config_error"
        confidence=85
        evidence+=("Configuration error detected")
        [[ "$error_message" =~ config ]] && evidence+=("Missing or invalid configuration")
        [[ "$error_message" =~ template ]] && evidence+=("Unknown pipeline template")
    # ─── External Dependency Failures ───────────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(npm ERR|pip.*install|gem.*install|cargo.*error|go.*get|npm:.*not found|cannot find module|dependency.*fail)'; then
        category="external_dep"
        confidence=80
        evidence+=("Dependency installation failure")
        [[ "$error_message" =~ npm ]] && evidence+=("npm dependency issue")
        [[ "$error_message" =~ pip ]] && evidence+=("Python pip issue")
        [[ "$error_message" =~ cargo ]] && evidence+=("Rust cargo issue")
    # ─── Code Bug Detection ──────────────────────────────────────────────────────
    elif echo "$error_message" | grep -qiE '(AssertionError|assert.*fail|Expected.*but.*got|TypeError|ReferenceError|SyntaxError|CompileError|type mismatch|cannot assign|incompatible type|FAILED.*test|Test.*failed|test.*fail)'; then
        category="code_bug"
        confidence=85
        evidence+=("Code logic error detected")
        [[ "$exit_code" != "0" ]] && evidence+=("Non-zero exit code")
        [[ "$stage" == "test" ]] && evidence+=("Failure in test stage")
    fi

    # ─── Default to code_bug if no match ────────────────────────────────────────
    if [[ "$category" == "unknown" ]]; then
        category="code_bug"
        confidence=45
        evidence+=("No infrastructure/platform patterns detected; likely user code issue")
    fi

    # Output JSON result
    printf '{"category":"%s","confidence":%d,"evidence":%s,"suggested_action":"See rootcause_suggest_fix"}\n' \
        "$category" "$confidence" "$(printf '"%s"' "${evidence[@]}" | jq -Rs 'split("\n") | map(select(length > 0))')"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Analyze error-log.jsonl for error patterns
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_analyze_error_log() {
    local error_log="${ARTIFACTS_DIR}/error-log.jsonl"
    [[ ! -f "$error_log" ]] && { echo '{"patterns_analyzed":0,"top_categories":[],"summary":"No error log found"}'; return 0; }

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    trap "rm -rf '$tmp_dir'" RETURN

    # Analyze each error entry and collect classifications
    local classifications="$tmp_dir/classifications.json"
    > "$classifications"

    local entry_count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local error_msg
        error_msg=$(echo "$line" | jq -r '.error // .message // .' 2>/dev/null || echo "$line")
        [[ -z "$error_msg" || "$error_msg" == "null" ]] && continue

        local classification
        classification=$(rootcause_classify "$error_msg" "unknown" "1" 2>/dev/null || echo '{}')
        echo "$classification" >> "$classifications"
        entry_count=$((entry_count + 1))
    done < <(tail -50 "$error_log" 2>/dev/null)

    # Count patterns by category
    local summary
    if [[ "$entry_count" -gt 0 ]]; then
        summary=$(jq -s '[.[] | .category] | group_by(.) | map({category: .[0], count: length}) | sort_by(-.count)' "$classifications" 2>/dev/null || echo "[]")
    else
        summary="[]"
    fi

    # Safely output JSON
    echo '{"patterns_analyzed":'$entry_count',"top_categories":'$summary',"summary":"Analysis complete"}'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Create GitHub issue for platform bugs
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_create_platform_issue() {
    local classification_json="${1:-}"
    local error_message="${2:-}"
    local stage="${3:-unknown}"

    [[ -n "$NO_GITHUB" ]] && { info "Skipping GitHub issue creation (NO_GITHUB set)"; return 0; }
    [[ ! -x "$(command -v gh 2>/dev/null)" ]] && { warn "gh CLI not found, cannot create issue"; return 1; }

    # Parse classification
    local category confidence
    category=$(echo "$classification_json" | jq -r '.category // "unknown"' 2>/dev/null || echo "unknown")
    confidence=$(echo "$classification_json" | jq -r '.confidence // 0' 2>/dev/null || echo "0")

    # Only create issues for high-confidence platform/config errors
    if [[ ! "$category" =~ ^(platform_bug|config_error)$ ]] || [[ "$confidence" -lt 70 ]]; then
        info "Skipping issue creation: category=$category, confidence=$confidence (threshold: platform_bug|config_error with >70%)"
        return 0
    fi

    # Check for duplicate issues first
    local error_sig
    error_sig=$(echo "$error_message" | cksum | awk '{print $1}')
    local existing_issues
    existing_issues=$(gh issue list --state open --search "error-sig:$error_sig" --limit 1 2>/dev/null || true)

    if [[ -n "$existing_issues" ]]; then
        info "Duplicate issue already exists for error signature $error_sig"
        echo "$existing_issues" | grep -oE '#[0-9]+' | head -1
        return 0
    fi

    # Build issue body with context
    local pipeline_config="unknown"
    [[ -f "$STATE_DIR/pipeline-config.json" ]] && pipeline_config=$(cat "$STATE_DIR/pipeline-config.json" | head -20)

    local issue_title="[PLATFORM BUG] $category in $stage stage"
    local issue_body="## Root Cause Classification

**Category:** \`$category\`
**Confidence:** $confidence%
**Stage:** $stage
**Error Signature:** \`$error_sig\`

## Error Message
\`\`\`
$(echo "$error_message" | head -20)
\`\`\`

## Pipeline Configuration
\`\`\`json
$pipeline_config
\`\`\`

## System Info
- Shipwright version: $VERSION
- Pipeline state: see .claude/pipeline-state.md
- Error log: see .claude/pipeline-artifacts/error-log.jsonl

## Auto-Created
This issue was automatically created by Shipwright's root cause classifier.
If this is not a platform bug, please close with \`resolution:not-our-bug\`.
If you've fixed this, tag it with \`resolved\`.

---
error-sig: $error_sig
"

    # Create the issue
    local issue_url
    issue_url=$(gh issue create \
        --title "$issue_title" \
        --body "$issue_body" \
        --label "platform-bug,auto-created" \
        2>/dev/null || echo "")

    if [[ -n "$issue_url" ]]; then
        success "Created platform bug issue: $issue_url"
        echo "$issue_url" | grep -oE '#[0-9]+' | tr -d '#'
        emit_event "rootcause.platform_issue_created" "error_sig=$error_sig" "issue=$issue_url"
        return 0
    fi

    warn "Failed to create GitHub issue"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Suggest automated fixes by category
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_suggest_fix() {
    local category="${1:-unknown}"
    local error_message="${2:-}"
    local stage="${3:-unknown}"

    local suggestions=""
    local actionability=0

    case "$category" in
        rate_limit)
            suggestions="Rate limit detected. Suggested fixes: Wait and retry with exponential backoff, check API quota with shipwright cost show, reduce concurrency in daemon-config.json, time-shift pipeline execution to off-peak hours"
            actionability=85
            ;;
        context_exhaustion)
            suggestions="Context window exhausted. Suggested fixes: Increase max-restarts for fresh session, reduce codebase context via .claudeignore, simplify pipeline goal or break into subtasks, check memory usage with shipwright memory show"
            actionability=75
            ;;
        flatline)
            suggestions="Build loop flatlined (same error, no code change). Suggested fixes: Do not just add restarts, a fresh session repeats the failure; read the repeated error in .claude/loop-logs/error-summary.json, change approach or narrow the goal, check whether the test itself is wrong, escalate to the full template or a stronger model"
            actionability=80
            ;;
        infra_issue)
            suggestions="Infrastructure problem. Suggested fixes: Check disk space with df -h, check memory with free -h or vm_stat, check network connectivity with ping github.com, restart daemon, check system load with uptime"
            actionability=70
            ;;
        platform_bug)
            suggestions="Shipwright platform bug. Suggested fixes: Check .claude/pipeline-state.md for context, run shipwright doctor to validate setup, review recent changes with git log, check .claude/hooks for interfering hooks, upgrade with shipwright upgrade"
            actionability=80
            ;;
        config_error)
            suggestions="Configuration error. Suggested fixes: Run shipwright doctor to validate setup, check .claude/daemon-config.json for syntax errors, verify environment variables, check pipeline template exists, review .claudeignore and .claude/rules"
            actionability=90
            ;;
        external_dep)
            suggestions="External dependency failure. Suggested fixes: Clear dependency cache, retry install with npm install or pip install, check package registry health, increase timeout for slow networks, try offline mirror or alternative registry"
            actionability=75
            ;;
        code_bug)
            suggestions="Code logic error in user code. Suggested fixes: Review test output in .claude/pipeline-artifacts, check recent commits with git diff, run tests locally, enable debug logging for the stage, use shipwright loop with debug mode"
            actionability=65
            ;;
        *)
            suggestions="Unknown error. Start debugging: Check error logs in .claude/pipeline-artifacts, run shipwright doctor for setup validation, enable verbose logging with DEBUG=1, review pipeline state with shipwright status"
            actionability=50
            ;;
    esac

    # Use jq to safely create JSON with proper escaping
    jq -n --arg cat "$category" --arg sug "$suggestions" --arg act "$actionability" \
        '{category: $cat, suggestions: $sug, actionability: ($act | tonumber)}'
}

# ═══════════════════════════════════════════════════════════════════════════════
# Feed classified failures into learning system
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_learn() {
    local category="${1:-unknown}"
    local confidence="${2:-0}"
    local error_message="${3:-}"

    local learn_file="${HOME}/.shipwright/optimization/root-causes.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization" 2>/dev/null || return 1

    local entry
    entry=$(jq -c -n \
        --arg cat "$category" \
        --arg conf "$confidence" \
        --arg msg "$(echo "$error_message" | head -c 200)" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{category: $cat, confidence: ($conf | tonumber), message: $msg, recorded_at: $ts}')

    # Atomic append
    local tmp_learn
    tmp_learn=$(mktemp) || return 1
    echo "$entry" >> "$tmp_learn"
    cat "$learn_file" >> "$tmp_learn" 2>/dev/null || true
    mv "$tmp_learn" "$learn_file" 2>/dev/null || { rm -f "$tmp_learn"; return 1; }
    chmod 600 "$learn_file" 2>/dev/null || true

    emit_event "rootcause.learned" "category=$category" "confidence=$confidence"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Generate root cause report
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_report() {
    local learn_file="${HOME}/.shipwright/optimization/root-causes.jsonl"
    [[ ! -f "$learn_file" ]] && { info "No root cause history yet"; return 0; }

    local total_entries
    total_entries=$(wc -l < "$learn_file" 2>/dev/null || echo "0")

    # Category distribution
    local dist
    dist=$(jq -s 'group_by(.category) | map({category: .[0].category, count: length}) | sort_by(-.count)' "$learn_file" 2>/dev/null || echo "[]")

    # Top 5 most frequent root causes (by message)
    local top_5
    top_5=$(jq -s 'group_by(.message) | map({message: .[0].message, category: .[0].category, occurrences: length}) | sort_by(-.occurrences) | .[0:5]' "$learn_file" 2>/dev/null || echo "[]")

    # Trend: are platform bugs increasing?
    local platform_bugs_1d platform_bugs_7d
    platform_bugs_1d=$(jq -s --arg cutoff "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1d +%Y-%m-%dT%H:%M:%SZ)" \
        "[.[] | select(.recorded_at > \$cutoff and .category == \"platform_bug\")] | length" "$learn_file" 2>/dev/null || echo "0")
    platform_bugs_7d=$(jq -s --arg cutoff "$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)" \
        "[.[] | select(.recorded_at > \$cutoff and .category == \"platform_bug\")] | length" "$learn_file" 2>/dev/null || echo "0")

    # MTTR by category
    local mttr_by_cat
    mttr_by_cat=$(jq -s 'group_by(.category) | map({category: .[0].category, avg_confidence: (map(.confidence) | add / length)}) | sort_by(-.avg_confidence)' "$learn_file" 2>/dev/null || echo "[]")

    {
        echo "═══════════════════════════════════════════════════════════════════════════"
        echo "                   Root Cause Analysis Report"
        echo "═══════════════════════════════════════════════════════════════════════════"
        echo ""
        echo "Total analyzed failures: $total_entries"
        echo ""
        echo "─── Category Distribution ───────────────────────────────────────────────────"
        echo "$dist" | jq -r '.[] | "  \(.category): \(.count) occurrences"'
        echo ""
        echo "─── Top 5 Most Frequent Root Causes ──────────────────────────────────────"
        echo "$top_5" | jq -r '.[] | "  [\(.category)] \(.occurrences)x: \(.message | .[0:70])"'
        echo ""
        echo "─── Platform Bug Trend ───────────────────────────────────────────────────"
        echo "  Last 24h: $platform_bugs_1d platform bugs"
        echo "  Last 7d:  $platform_bugs_7d platform bugs"
        [[ "$platform_bugs_7d" -gt 0 ]] && {
            local trend
            trend=$((platform_bugs_1d * 100 / platform_bugs_7d))
            [[ "$trend" -gt 100 ]] && echo "  ⚠️  INCREASING trend!" || echo "  ✓ Decreasing or stable"
        }
        echo ""
        echo "─── Average Confidence by Category ───────────────────────────────────────"
        echo "$mttr_by_cat" | jq -r '.[] | "  \(.category): \(.avg_confidence | round)% confidence"'
        echo ""
        echo "═══════════════════════════════════════════════════════════════════════════"
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main entry point: Classify and optionally create issue
# ═══════════════════════════════════════════════════════════════════════════════

rootcause_main() {
    local error_message="${1:-}"
    local stage="${2:-unknown}"
    local exit_code="${3:-1}"

    [[ -z "$error_message" ]] && { error "Usage: rootcause_main <error_message> [stage] [exit_code]"; return 1; }

    # Classify the error
    local classification
    classification=$(rootcause_classify "$error_message" "$stage" "$exit_code")

    # Extract category and confidence
    local category confidence
    category=$(echo "$classification" | jq -r '.category' 2>/dev/null || echo "unknown")
    confidence=$(echo "$classification" | jq -r '.confidence' 2>/dev/null || echo "0")

    # Suggest fix
    local fix_suggestion
    fix_suggestion=$(rootcause_suggest_fix "$category" "$error_message" "$stage")

    # Learn from this failure
    rootcause_learn "$category" "$confidence" "$error_message"

    # Try to create issue for platform bugs
    [[ "$category" =~ ^(platform_bug|config_error)$ ]] && [[ "$confidence" -gt 70 ]] && {
        rootcause_create_platform_issue "$classification" "$error_message" "$stage" || true
    }

    # Output result
    printf '{"classification":%s,"fix":%s}\n' "$classification" "$fix_suggestion"
}
