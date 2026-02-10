#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence — AI-Powered Analysis & Decision Engine        ║
# ║  Semantic issue analysis · Pipeline composition · Cost prediction       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

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

# ─── Intelligence Configuration ─────────────────────────────────────────────
INTELLIGENCE_CACHE="${REPO_DIR}/.claude/intelligence-cache.json"
DEFAULT_CACHE_TTL=3600  # 1 hour

# ─── Feature Flag ───────────────────────────────────────────────────────────

_intelligence_enabled() {
    local config="${REPO_DIR}/.claude/daemon-config.json"
    if [[ -f "$config" ]]; then
        local enabled
        enabled=$(jq -r '.intelligence.enabled // false' "$config" 2>/dev/null || echo "false")
        [[ "$enabled" == "true" ]]
    else
        return 1
    fi
}

# ─── Cross-platform MD5 ─────────────────────────────────────────────────────

_intelligence_md5() {
    local input="${1:-}"
    if [[ -z "$input" ]]; then
        # Read from stdin (piped usage)
        input=$(cat)
    fi
    echo -n "$input" | md5 2>/dev/null || echo -n "$input" | md5sum | cut -d' ' -f1
}

# ─── Cache Operations ───────────────────────────────────────────────────────

_intelligence_cache_init() {
    local cache_dir
    cache_dir="$(dirname "$INTELLIGENCE_CACHE")"
    mkdir -p "$cache_dir"
    if [[ ! -f "$INTELLIGENCE_CACHE" ]]; then
        echo '{"entries":{}}' > "$INTELLIGENCE_CACHE"
    fi
}

_intelligence_cache_get() {
    local cache_key="$1"
    local ttl="${2:-$DEFAULT_CACHE_TTL}"

    _intelligence_cache_init

    local hash
    hash=$(_intelligence_md5 "$cache_key")

    local entry
    entry=$(jq -r --arg h "$hash" '.entries[$h] // empty' "$INTELLIGENCE_CACHE" 2>/dev/null || true)

    if [[ -z "$entry" ]]; then
        return 1
    fi

    local cached_ts
    cached_ts=$(echo "$entry" | jq -r '.timestamp // 0')
    local now
    now=$(now_epoch)
    local age=$(( now - cached_ts ))

    if [[ "$age" -gt "$ttl" ]]; then
        return 1
    fi

    echo "$entry" | jq -r '.result'
    return 0
}

_intelligence_cache_set() {
    local cache_key="$1"
    local result="$2"
    local ttl="${3:-$DEFAULT_CACHE_TTL}"

    _intelligence_cache_init

    local hash
    hash=$(_intelligence_md5 "$cache_key")
    local now
    now=$(now_epoch)

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-intel-cache.XXXXXX")
    jq --arg h "$hash" \
       --argjson result "$result" \
       --argjson ts "$now" \
       --argjson ttl "$ttl" \
       '.entries[$h] = {"result": $result, "timestamp": $ts, "ttl": $ttl}' \
       "$INTELLIGENCE_CACHE" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$INTELLIGENCE_CACHE" || rm -f "$tmp_file"
}

# ─── Core Claude Call ────────────────────────────────────────────────────────

_intelligence_call_claude() {
    local prompt="$1"
    local cache_key="$2"
    local ttl="${3:-$DEFAULT_CACHE_TTL}"

    # Check cache first
    local cached
    if cached=$(_intelligence_cache_get "$cache_key" "$ttl"); then
        emit_event "intelligence.cache_hit" "cache_key=$cache_key"
        echo "$cached"
        return 0
    fi

    # Verify claude CLI is available
    if ! command -v claude >/dev/null 2>&1; then
        error "claude CLI not found"
        echo '{"error":"claude_cli_not_found"}'
        return 1
    fi

    # Call Claude
    local response
    if ! response=$(claude -p "$prompt" --output-format json 2>/dev/null); then
        error "Claude call failed"
        echo '{"error":"claude_call_failed"}'
        return 1
    fi

    # Extract the text result from Claude's response
    local result
    result=$(echo "$response" | jq -r '.result // .content // .' 2>/dev/null || echo "$response")

    # Try to parse as JSON — if the result is a JSON string inside the response, extract it
    local parsed
    if parsed=$(echo "$result" | jq '.' 2>/dev/null); then
        result="$parsed"
    else
        # Attempt to extract JSON from markdown code blocks
        local extracted
        extracted=$(echo "$result" | sed -n '/^```json/,/^```$/p' | sed '1d;$d' || true)
        if [[ -n "$extracted" ]] && echo "$extracted" | jq '.' >/dev/null 2>&1; then
            result="$extracted"
        else
            # Wrap raw text in a JSON object
            result=$(jq -n --arg text "$result" '{"raw_response": $text}')
        fi
    fi

    # Cache the result
    _intelligence_cache_set "$cache_key" "$result" "$ttl"

    echo "$result"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# PUBLIC FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

# ─── Analyze Issue ───────────────────────────────────────────────────────────

intelligence_analyze_issue() {
    local issue_json="${1:-"{}"}"

    if ! _intelligence_enabled; then
        echo '{"error":"intelligence_disabled","complexity":5,"risk_level":"medium","success_probability":50,"recommended_template":"standard","key_risks":[],"implementation_hints":[]}'
        return 0
    fi

    local title body labels
    title=$(echo "$issue_json" | jq -r '.title // "untitled"' 2>/dev/null || echo "untitled")
    body=$(echo "$issue_json" | jq -r '.body // ""' 2>/dev/null || echo "")
    labels=$(echo "$issue_json" | jq -r '(.labels // []) | join(", ")' 2>/dev/null || echo "")

    local prompt
    prompt="Analyze this GitHub issue for a software project and return ONLY a JSON object (no markdown, no explanation).

Issue title: ${title}
Issue body: ${body}
Labels: ${labels}

Return JSON with exactly these fields:
{
  \"complexity\": <number 1-10>,
  \"risk_level\": \"<low|medium|high|critical>\",
  \"success_probability\": <number 0-100>,
  \"recommended_template\": \"<fast|standard|full|hotfix|autonomous|enterprise|cost-aware>\",
  \"key_risks\": [\"risk1\", \"risk2\"],
  \"implementation_hints\": [\"hint1\", \"hint2\"]
}"

    local cache_key
    cache_key="analyze_issue_$(_intelligence_md5 "${title}${body}")"

    local result
    if result=$(_intelligence_call_claude "$prompt" "$cache_key"); then
        # Validate schema: ensure required fields exist
        local valid
        valid=$(echo "$result" | jq 'has("complexity") and has("risk_level") and has("success_probability") and has("recommended_template")' 2>/dev/null || echo "false")

        if [[ "$valid" != "true" ]]; then
            warn "Intelligence response missing required fields, using fallback"
            result='{"complexity":5,"risk_level":"medium","success_probability":50,"recommended_template":"standard","key_risks":["analysis_incomplete"],"implementation_hints":[]}'
        fi

        emit_event "intelligence.analysis" \
            "complexity=$(echo "$result" | jq -r '.complexity')" \
            "risk_level=$(echo "$result" | jq -r '.risk_level')" \
            "success_probability=$(echo "$result" | jq -r '.success_probability')" \
            "recommended_template=$(echo "$result" | jq -r '.recommended_template')"

        echo "$result"
        return 0
    else
        echo '{"error":"analysis_failed","complexity":5,"risk_level":"medium","success_probability":50,"recommended_template":"standard","key_risks":["analysis_failed"],"implementation_hints":[]}'
        return 0
    fi
}

# ─── Compose Pipeline ───────────────────────────────────────────────────────

intelligence_compose_pipeline() {
    local issue_analysis="${1:-"{}"}"
    local repo_context="${2:-"{}"}"
    local budget="${3:-0}"

    if ! _intelligence_enabled; then
        echo '{"error":"intelligence_disabled","stages":[]}'
        return 0
    fi

    local complexity risk_level
    complexity=$(echo "$issue_analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")
    risk_level=$(echo "$issue_analysis" | jq -r '.risk_level // "medium"' 2>/dev/null || echo "medium")

    local prompt
    prompt="You are a CI/CD pipeline composer. Given the issue analysis and constraints, compose an optimal pipeline.

Issue complexity: ${complexity}/10
Risk level: ${risk_level}
Budget remaining: \$${budget} USD
Repository context: ${repo_context}

Available stages: intake, plan, design, build, test, review, compound_quality, pr, merge, deploy, validate, monitor
Available models: opus (most capable, expensive), sonnet (balanced), haiku (fast, cheap)

Return ONLY a JSON object (no markdown):
{
  \"stages\": [
    {\"id\": \"stage_name\", \"enabled\": true, \"model\": \"sonnet\", \"config\": {}}
  ],
  \"rationale\": \"brief explanation\"
}"

    local cache_key
    cache_key="compose_pipeline_$(_intelligence_md5 "${issue_analysis}${budget}")"

    local result
    if result=$(_intelligence_call_claude "$prompt" "$cache_key"); then
        local has_stages
        has_stages=$(echo "$result" | jq 'has("stages") and (.stages | type == "array")' 2>/dev/null || echo "false")

        if [[ "$has_stages" != "true" ]]; then
            warn "Pipeline composition missing stages array, using fallback"
            result='{"stages":[{"id":"intake","enabled":true,"model":"sonnet","config":{}},{"id":"build","enabled":true,"model":"sonnet","config":{}},{"id":"test","enabled":true,"model":"sonnet","config":{}},{"id":"pr","enabled":true,"model":"sonnet","config":{}}],"rationale":"fallback pipeline"}'
        fi

        emit_event "intelligence.compose" \
            "stage_count=$(echo "$result" | jq '.stages | length')" \
            "complexity=$complexity"

        echo "$result"
        return 0
    else
        echo '{"error":"composition_failed","stages":[]}'
        return 0
    fi
}

# ─── Predict Cost ────────────────────────────────────────────────────────────

intelligence_predict_cost() {
    local issue_analysis="${1:-"{}"}"
    local historical_data="${2:-"{}"}"

    if ! _intelligence_enabled; then
        echo '{"error":"intelligence_disabled","estimated_cost_usd":0,"estimated_iterations":0,"likely_failure_stage":"unknown"}'
        return 0
    fi

    local complexity
    complexity=$(echo "$issue_analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")

    local prompt
    prompt="Estimate the cost and effort for a CI pipeline run. Return ONLY JSON (no markdown).

Issue analysis: ${issue_analysis}
Historical data from past runs: ${historical_data}

Based on similar complexity (${complexity}/10) issues, estimate:
{
  \"estimated_cost_usd\": <number>,
  \"estimated_iterations\": <number of build-test cycles>,
  \"estimated_tokens\": <total token count>,
  \"likely_failure_stage\": \"<stage name or 'none'>\",
  \"confidence\": <0-100>
}"

    local cache_key
    cache_key="predict_cost_$(_intelligence_md5 "${issue_analysis}${historical_data}")"

    local result
    if result=$(_intelligence_call_claude "$prompt" "$cache_key"); then
        local valid
        valid=$(echo "$result" | jq 'has("estimated_cost_usd") and has("estimated_iterations")' 2>/dev/null || echo "false")

        if [[ "$valid" != "true" ]]; then
            warn "Cost prediction missing required fields, using fallback"
            result='{"estimated_cost_usd":5.0,"estimated_iterations":3,"estimated_tokens":500000,"likely_failure_stage":"test","confidence":30}'
        fi

        emit_event "intelligence.prediction" \
            "estimated_cost=$(echo "$result" | jq -r '.estimated_cost_usd')" \
            "estimated_iterations=$(echo "$result" | jq -r '.estimated_iterations')" \
            "complexity=$complexity"

        echo "$result"
        return 0
    else
        echo '{"error":"prediction_failed","estimated_cost_usd":0,"estimated_iterations":0,"likely_failure_stage":"unknown"}'
        return 0
    fi
}

# ─── Synthesize Findings ─────────────────────────────────────────────────────

intelligence_synthesize_findings() {
    local findings_json="${1:-"[]"}"

    if ! _intelligence_enabled; then
        echo '{"error":"intelligence_disabled","priority_fixes":[],"root_causes":[],"recommended_approach":""}'
        return 0
    fi

    local prompt
    prompt="Synthesize multiple signal sources (patrol findings, test results, review comments) into a unified fix strategy. Return ONLY JSON (no markdown).

Findings: ${findings_json}

Return:
{
  \"priority_fixes\": [\"fix1\", \"fix2\"],
  \"root_causes\": [\"cause1\", \"cause2\"],
  \"recommended_approach\": \"description of unified strategy\",
  \"estimated_effort\": \"<low|medium|high>\"
}"

    local cache_key
    cache_key="synthesize_$(_intelligence_md5 "$findings_json")"

    local result
    if result=$(_intelligence_call_claude "$prompt" "$cache_key"); then
        local valid
        valid=$(echo "$result" | jq 'has("priority_fixes") and has("root_causes")' 2>/dev/null || echo "false")

        if [[ "$valid" != "true" ]]; then
            result='{"priority_fixes":[],"root_causes":["analysis_incomplete"],"recommended_approach":"manual review needed","estimated_effort":"medium"}'
        fi

        emit_event "intelligence.synthesize" \
            "fix_count=$(echo "$result" | jq '.priority_fixes | length')" \
            "cause_count=$(echo "$result" | jq '.root_causes | length')"

        echo "$result"
        return 0
    else
        echo '{"error":"synthesis_failed","priority_fixes":[],"root_causes":[],"recommended_approach":""}'
        return 0
    fi
}

# ─── Search Memory ───────────────────────────────────────────────────────────

intelligence_search_memory() {
    local context="${1:-""}"
    local memory_dir="${2:-"${HOME}/.shipwright/memory"}"
    local top_n="${3:-5}"

    if ! _intelligence_enabled; then
        echo '{"error":"intelligence_disabled","results":[]}'
        return 0
    fi

    # Gather memory file contents
    local memory_content=""
    if [[ -d "$memory_dir" ]]; then
        local file_list=""
        local count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fname
            fname=$(basename "$f")
            local content
            content=$(head -100 "$f" 2>/dev/null || true)
            if [[ -n "$content" ]]; then
                file_list="${file_list}
--- ${fname} ---
${content}
"
                count=$((count + 1))
            fi
        done < <(find "$memory_dir" -name "*.json" -o -name "*.md" 2>/dev/null | head -20 || true)

        if [[ "$count" -eq 0 ]]; then
            echo '{"results":[],"message":"no memory files found"}'
            return 0
        fi
        memory_content="$file_list"
    else
        echo '{"results":[],"message":"memory directory not found"}'
        return 0
    fi

    local prompt
    prompt="Rank the following memory entries by relevance to this context. Return ONLY JSON (no markdown).

Context: ${context}

Memory entries:
${memory_content}

Return the top ${top_n} most relevant entries:
{
  \"results\": [
    {\"file\": \"filename\", \"relevance\": <0-100>, \"summary\": \"why this is relevant\"}
  ]
}"

    local cache_key
    cache_key="search_memory_$(_intelligence_md5 "${context}${memory_dir}")"

    local result
    if result=$(_intelligence_call_claude "$prompt" "$cache_key" 1800); then
        local valid
        valid=$(echo "$result" | jq 'has("results") and (.results | type == "array")' 2>/dev/null || echo "false")

        if [[ "$valid" != "true" ]]; then
            result='{"results":[]}'
        fi

        echo "$result"
        return 0
    else
        echo '{"error":"memory_search_failed","results":[]}'
        return 0
    fi
}

# ─── Recommend Model ─────────────────────────────────────────────────────────

intelligence_recommend_model() {
    local stage="${1:-"build"}"
    local complexity="${2:-5}"
    local budget_remaining="${3:-100}"

    # This function uses heuristics first, with optional Claude refinement
    local model="sonnet"
    local reason="default balanced choice"

    # Budget-constrained: use haiku
    if [[ "$budget_remaining" != "" ]] && [[ "$(echo "$budget_remaining < 5" | bc 2>/dev/null || echo "0")" == "1" ]]; then
        model="haiku"
        reason="budget constrained (< \$5 remaining)"
    # High complexity + critical stages: use opus
    elif [[ "$complexity" -ge 8 ]]; then
        case "$stage" in
            plan|design|review|compound_quality)
                model="opus"
                reason="high complexity (${complexity}/10) + critical stage (${stage})"
                ;;
            build|test)
                model="sonnet"
                reason="high complexity but execution stage — sonnet is sufficient"
                ;;
            *)
                model="sonnet"
                reason="high complexity, non-critical stage"
                ;;
        esac
    # Low complexity: use haiku for simple stages
    elif [[ "$complexity" -le 3 ]]; then
        case "$stage" in
            intake|pr|merge)
                model="haiku"
                reason="low complexity (${complexity}/10), simple stage (${stage})"
                ;;
            build|test)
                model="sonnet"
                reason="low complexity but code execution stage"
                ;;
            *)
                model="haiku"
                reason="low complexity, standard stage"
                ;;
        esac
    fi

    local result
    result=$(jq -n --arg model "$model" --arg reason "$reason" --arg stage "$stage" --argjson complexity "$complexity" \
        '{"model": $model, "reason": $reason, "stage": $stage, "complexity": $complexity}')

    emit_event "intelligence.model" \
        "stage=$stage" \
        "complexity=$complexity" \
        "model=$model"

    echo "$result"
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI INTERFACE
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${CYAN}${BOLD}shipwright intelligence${RESET} — AI-Powered Analysis & Decision Engine"
    echo ""
    echo -e "${BOLD}USAGE${RESET}"
    echo -e "  shipwright intelligence <command> [options]"
    echo ""
    echo -e "${BOLD}COMMANDS${RESET}"
    echo -e "  ${CYAN}analyze${RESET} <issue_json>          Analyze an issue semantically"
    echo -e "  ${CYAN}compose${RESET} <analysis> [ctx] [$$]  Compose optimal pipeline"
    echo -e "  ${CYAN}predict${RESET} <analysis> [history]   Predict cost and effort"
    echo -e "  ${CYAN}synthesize${RESET} <findings_json>     Synthesize findings into strategy"
    echo -e "  ${CYAN}search-memory${RESET} <context> [dir]  Search memory by relevance"
    echo -e "  ${CYAN}recommend-model${RESET} <stage> [cplx] Recommend model for stage"
    echo -e "  ${CYAN}cache-stats${RESET}                    Show cache statistics"
    echo -e "  ${CYAN}cache-clear${RESET}                    Clear intelligence cache"
    echo -e "  ${CYAN}help${RESET}                           Show this help"
    echo ""
    echo -e "${BOLD}CONFIGURATION${RESET}"
    echo -e "  Enable in ${DIM}.claude/daemon-config.json${RESET}:"
    echo -e "    ${DIM}{\"intelligence\": {\"enabled\": true}}${RESET}"
    echo ""
    echo -e "${DIM}Version ${VERSION}${RESET}"
}

cmd_cache_stats() {
    _intelligence_cache_init

    local entry_count
    entry_count=$(jq '.entries | length' "$INTELLIGENCE_CACHE" 2>/dev/null || echo "0")
    local cache_size
    cache_size=$(wc -c < "$INTELLIGENCE_CACHE" 2>/dev/null | tr -d ' ' || echo "0")

    echo ""
    echo -e "${BOLD}Intelligence Cache${RESET}"
    echo -e "  Entries:  ${CYAN}${entry_count}${RESET}"
    echo -e "  Size:     ${DIM}${cache_size} bytes${RESET}"
    echo -e "  Location: ${DIM}${INTELLIGENCE_CACHE}${RESET}"

    if [[ "$entry_count" -gt 0 ]]; then
        local now
        now=$(now_epoch)
        local expired=0
        local active=0
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local ts ttl
            ts=$(jq -r --arg k "$key" '.entries[$k].timestamp // 0' "$INTELLIGENCE_CACHE" 2>/dev/null || echo "0")
            ttl=$(jq -r --arg k "$key" '.entries[$k].ttl // 3600' "$INTELLIGENCE_CACHE" 2>/dev/null || echo "3600")
            local age=$(( now - ts ))
            if [[ "$age" -gt "$ttl" ]]; then
                expired=$((expired + 1))
            else
                active=$((active + 1))
            fi
        done < <(jq -r '.entries | keys[]' "$INTELLIGENCE_CACHE" 2>/dev/null || true)
        echo -e "  Active:   ${GREEN}${active}${RESET}"
        echo -e "  Expired:  ${DIM}${expired}${RESET}"
    fi
    echo ""
}

cmd_cache_clear() {
    if [[ -f "$INTELLIGENCE_CACHE" ]]; then
        echo '{"entries":{}}' > "$INTELLIGENCE_CACHE"
        success "Intelligence cache cleared"
    else
        info "No cache file found"
    fi
}

main() {
    local cmd="${1:-help}"
    shift 2>/dev/null || true

    case "$cmd" in
        analyze)
            intelligence_analyze_issue "$@"
            ;;
        compose)
            intelligence_compose_pipeline "$@"
            ;;
        predict)
            intelligence_predict_cost "$@"
            ;;
        synthesize)
            intelligence_synthesize_findings "$@"
            ;;
        search-memory)
            intelligence_search_memory "$@"
            ;;
        recommend-model)
            intelligence_recommend_model "$@"
            ;;
        cache-stats)
            cmd_cache_stats
            ;;
        cache-clear)
            cmd_cache_clear
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
