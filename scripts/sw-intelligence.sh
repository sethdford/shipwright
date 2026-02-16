#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence — AI-Powered Analysis & Decision Engine        ║
# ║  Semantic issue analysis · Pipeline composition · Cost prediction       ║
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

# ─── Intelligence Configuration ─────────────────────────────────────────────
INTELLIGENCE_CACHE="${REPO_DIR}/.claude/intelligence-cache.json"
INTELLIGENCE_CONFIG_DIR="${HOME}/.shipwright/optimization"
CACHE_TTL_CONFIG="${INTELLIGENCE_CONFIG_DIR}/cache-ttl.json"
CACHE_STATS_FILE="${INTELLIGENCE_CONFIG_DIR}/cache-stats.json"
DEFAULT_CACHE_TTL=3600  # 1 hour (fallback)

# Load adaptive cache TTL from config or use default
_intelligence_get_cache_ttl() {
    if [[ -f "$CACHE_TTL_CONFIG" ]]; then
        local ttl
        ttl=$(jq -r '.ttl // empty' "$CACHE_TTL_CONFIG" 2>/dev/null || true)
        if [[ -n "$ttl" && "$ttl" != "null" && "$ttl" -gt 0 ]] 2>/dev/null; then
            echo "$ttl"
            return 0
        fi
    fi
    echo "$DEFAULT_CACHE_TTL"
}

# Track cache hit/miss and adjust TTL
_intelligence_track_cache_access() {
    local hit_or_miss="${1:-miss}"  # "hit" or "miss"

    mkdir -p "$INTELLIGENCE_CONFIG_DIR"
    if [[ ! -f "$CACHE_STATS_FILE" ]]; then
        echo '{"hits":0,"misses":0,"total":0}' > "$CACHE_STATS_FILE"
    fi

    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-cache-stats.XXXXXX")
    if [[ "$hit_or_miss" == "hit" ]]; then
        jq '.hits += 1 | .total += 1' "$CACHE_STATS_FILE" > "$tmp_file" && mv "$tmp_file" "$CACHE_STATS_FILE" || rm -f "$tmp_file"
    else
        jq '.misses += 1 | .total += 1' "$CACHE_STATS_FILE" > "$tmp_file" && mv "$tmp_file" "$CACHE_STATS_FILE" || rm -f "$tmp_file"
    fi

    # Every 20 accesses, evaluate whether to adjust TTL
    local total
    total=$(jq '.total // 0' "$CACHE_STATS_FILE" 2>/dev/null || echo "0")
    if [[ "$((total % 20))" -eq 0 && "$total" -gt 0 ]]; then
        _intelligence_adjust_cache_ttl
    fi
}

# Adjust cache TTL based on hit/miss rates
_intelligence_adjust_cache_ttl() {
    [[ -f "$CACHE_STATS_FILE" ]] || return 0

    local hits misses total
    hits=$(jq '.hits // 0' "$CACHE_STATS_FILE" 2>/dev/null || echo "0")
    misses=$(jq '.misses // 0' "$CACHE_STATS_FILE" 2>/dev/null || echo "0")
    total=$(jq '.total // 0' "$CACHE_STATS_FILE" 2>/dev/null || echo "0")

    [[ "$total" -lt 10 ]] && return 0

    local miss_rate
    miss_rate=$(awk -v m="$misses" -v t="$total" 'BEGIN { printf "%.0f", (m / t) * 100 }')

    local current_ttl
    current_ttl=$(_intelligence_get_cache_ttl)
    local new_ttl="$current_ttl"

    if [[ "$miss_rate" -gt 30 ]]; then
        # High miss rate — reduce TTL (data getting stale too often)
        new_ttl=$(awk -v ttl="$current_ttl" 'BEGIN { v = int(ttl * 0.75); if (v < 300) v = 300; print v }')
    elif [[ "$miss_rate" -lt 5 ]]; then
        # Very low miss rate — increase TTL (cache is very effective)
        new_ttl=$(awk -v ttl="$current_ttl" 'BEGIN { v = int(ttl * 1.25); if (v > 14400) v = 14400; print v }')
    fi

    if [[ "$new_ttl" != "$current_ttl" ]]; then
        local tmp_file
        tmp_file=$(mktemp "${TMPDIR:-/tmp}/sw-cache-ttl.XXXXXX")
        jq -n \
            --argjson ttl "$new_ttl" \
            --argjson miss_rate "$miss_rate" \
            --arg updated "$(now_iso)" \
            '{ttl: $ttl, miss_rate_pct: $miss_rate, updated: $updated}' \
            > "$tmp_file" && mv "$tmp_file" "$CACHE_TTL_CONFIG" || rm -f "$tmp_file"

        emit_event "intelligence.cache_ttl_adjusted" \
            "old_ttl=$current_ttl" \
            "new_ttl=$new_ttl" \
            "miss_rate=$miss_rate"
    fi

    # Reset stats for next window
    local tmp_reset
    tmp_reset=$(mktemp "${TMPDIR:-/tmp}/sw-cache-reset.XXXXXX")
    echo '{"hits":0,"misses":0,"total":0}' > "$tmp_reset" && mv "$tmp_reset" "$CACHE_STATS_FILE" || rm -f "$tmp_reset"
}

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

# MD5 hashing: uses compute_md5 from lib/compat.sh

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
    local adaptive_ttl
    adaptive_ttl=$(_intelligence_get_cache_ttl)
    local ttl="${2:-$adaptive_ttl}"

    _intelligence_cache_init

    local hash
    hash=$(compute_md5 --string "$cache_key")

    local entry
    entry=$(jq -r --arg h "$hash" '.entries[$h] // empty' "$INTELLIGENCE_CACHE" 2>/dev/null || true)

    if [[ -z "$entry" ]]; then
        _intelligence_track_cache_access "miss"
        return 1
    fi

    local cached_ts
    cached_ts=$(echo "$entry" | jq -r '.timestamp // 0')
    local now
    now=$(now_epoch)
    local age=$(( now - cached_ts ))

    if [[ "$age" -gt "$ttl" ]]; then
        _intelligence_track_cache_access "miss"
        return 1
    fi

    _intelligence_track_cache_access "hit"
    echo "$entry" | jq -r '.result'
    return 0
}

_intelligence_cache_set() {
    local cache_key="$1"
    local result="$2"
    local ttl="${3:-$DEFAULT_CACHE_TTL}"

    _intelligence_cache_init

    local hash
    hash=$(compute_md5 --string "$cache_key")
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
    local cache_key="${2:-}"
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

    # Call Claude (--print mode returns raw text response)
    local response
    if ! response=$(claude -p "$prompt" 2>/dev/null); then
        error "Claude call failed"
        echo '{"error":"claude_call_failed"}'
        return 1
    fi

    # Extract JSON from the response
    local result
    # First try: raw response is valid JSON directly
    if echo "$response" | jq '.' >/dev/null 2>&1; then
        result=$(echo "$response" | jq '.')
    else
        # Second try: extract JSON from markdown code blocks (```json ... ```)
        local extracted
        extracted=$(echo "$response" | sed -n '/^```/,/^```$/p' | sed '1d;$d' || true)
        if [[ -n "$extracted" ]] && echo "$extracted" | jq '.' >/dev/null 2>&1; then
            result="$extracted"
        else
            # Third try: find first { to last } in response
            local braced
            braced=$(echo "$response" | sed -n '/{/,/}/p' || true)
            if [[ -n "$braced" ]] && echo "$braced" | jq '.' >/dev/null 2>&1; then
                result="$braced"
            else
                # Wrap raw text in a JSON object
                result=$(jq -n --arg text "$response" '{"raw_response": $text}')
            fi
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
    cache_key="analyze_issue_$(compute_md5 --string "${title}${body}")"

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

        # Enrich with GitHub data if available
        result=$(intelligence_github_enrich "$result")

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
    cache_key="compose_pipeline_$(compute_md5 --string "${issue_analysis}${budget}")"

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
    cache_key="predict_cost_$(compute_md5 --string "${issue_analysis}${historical_data}")"

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
    cache_key="synthesize_$(compute_md5 --string "$findings_json")"

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
    cache_key="search_memory_$(compute_md5 --string "${context}${memory_dir}")"

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

# ─── Estimate Iterations ─────────────────────────────────────────────────────

intelligence_estimate_iterations() {
    local issue_analysis="${1:-"{}"}"
    local historical_data="${2:-""}"

    local iteration_model="${HOME}/.shipwright/optimization/iteration-model.json"

    # Extract complexity from issue analysis (numeric 1-10)
    local complexity
    complexity=$(echo "$issue_analysis" | jq -r '.complexity // 5' 2>/dev/null || echo "5")

    # Map numeric complexity to bucket: 1-3=low, 4-6=medium, 7-10=high
    local bucket
    if [[ "$complexity" -le 3 ]]; then
        bucket="low"
    elif [[ "$complexity" -le 6 ]]; then
        bucket="medium"
    else
        bucket="high"
    fi

    # Strategy 1: Intelligence-enabled — call Claude for fine-grained estimation
    if _intelligence_enabled; then
        local prompt
        prompt="Estimate the number of build-test iterations needed for this issue. Return ONLY a JSON object.

Issue analysis: ${issue_analysis}
Historical iteration data: ${historical_data:-none}

Consider:
- Complexity: ${complexity}/10 (${bucket})
- Higher complexity usually needs more iterations
- Well-understood patterns need fewer iterations

Return JSON: {\"estimated_iterations\": <integer 1-50>}"

        local cache_key
        cache_key="estimate_iterations_$(compute_md5 --string "${issue_analysis}")"

        local result
        if result=$(_intelligence_call_claude "$prompt" "$cache_key" 1800); then
            # Extract number from result
            local estimate
            estimate=$(echo "$result" | jq -r '.estimated_iterations // .iterations // .estimate // empty' 2>/dev/null || true)
            if [[ -z "$estimate" ]]; then
                # Try raw number from response
                estimate=$(echo "$result" | jq -r '.raw_response // empty' 2>/dev/null | tr -dc '0-9' | head -c 3 || true)
            fi
            if [[ -n "$estimate" ]] && [[ "$estimate" =~ ^[0-9]+$ ]] && \
               [[ "$estimate" -ge 1 ]] && [[ "$estimate" -le 50 ]]; then
                emit_event "intelligence.estimate_iterations" \
                    "estimate=$estimate" \
                    "complexity=$complexity" \
                    "source=claude"
                echo "$estimate"
                return 0
            fi
        fi
        # Fall through to historical data if Claude call fails
    fi

    # Strategy 2: Use historical averages from iteration model
    if [[ -f "$iteration_model" ]]; then
        local mean samples
        mean=$(jq -r --arg b "$bucket" '.[$b].mean // 0' "$iteration_model" 2>/dev/null || echo "0")
        samples=$(jq -r --arg b "$bucket" '.[$b].samples // 0' "$iteration_model" 2>/dev/null || echo "0")

        if [[ "$samples" -gt 0 ]] && [[ "$mean" != "0" ]]; then
            # Round to nearest integer, clamp 1-50
            local estimate
            estimate=$(awk "BEGIN{v=int($mean + 0.5); if(v<1)v=1; if(v>50)v=50; print v}")
            emit_event "intelligence.estimate_iterations" \
                "estimate=$estimate" \
                "complexity=$complexity" \
                "source=historical" \
                "samples=$samples"
            echo "$estimate"
            return 0
        fi
    fi

    # Strategy 3: Heuristic fallback based on numeric complexity
    local estimate
    if [[ "$complexity" -le 2 ]]; then
        estimate=5
    elif [[ "$complexity" -le 4 ]]; then
        estimate=10
    elif [[ "$complexity" -le 6 ]]; then
        estimate=15
    elif [[ "$complexity" -le 8 ]]; then
        estimate=25
    else
        estimate=35
    fi

    emit_event "intelligence.estimate_iterations" \
        "estimate=$estimate" \
        "complexity=$complexity" \
        "source=heuristic"

    echo "$estimate"
    return 0
}

# ─── Recommend Model ─────────────────────────────────────────────────────────

intelligence_recommend_model() {
    local stage="${1:-"build"}"
    local complexity="${2:-5}"
    local budget_remaining="${3:-100}"

    local model="sonnet"
    local reason="default balanced choice"

    # Strategy 1: Check historical model routing data
    local routing_file="${HOME}/.shipwright/optimization/model-routing.json"
    if [[ -f "$routing_file" ]]; then
        local stage_data
        stage_data=$(jq -r --arg s "$stage" '.[$s] // empty' "$routing_file" 2>/dev/null || true)

        if [[ -n "$stage_data" && "$stage_data" != "null" ]]; then
            local recommended sonnet_rate sonnet_samples opus_rate opus_samples
            recommended=$(echo "$stage_data" | jq -r '.recommended // empty' 2>/dev/null || true)
            sonnet_rate=$(echo "$stage_data" | jq -r '.sonnet_rate // 0' 2>/dev/null || echo "0")
            sonnet_samples=$(echo "$stage_data" | jq -r '.sonnet_samples // 0' 2>/dev/null || echo "0")
            opus_rate=$(echo "$stage_data" | jq -r '.opus_rate // 0' 2>/dev/null || echo "0")
            opus_samples=$(echo "$stage_data" | jq -r '.opus_samples // 0' 2>/dev/null || echo "0")

            # Load adaptive routing thresholds from config or use defaults
            local routing_config="${HOME}/.shipwright/optimization/model-routing-thresholds.json"
            local min_samples=3
            local success_threshold=90
            local complexity_upgrade=8

            if [[ -f "$routing_config" ]]; then
                local cfg_min cfg_success cfg_complexity
                cfg_min=$(jq -r '.min_samples // empty' "$routing_config" 2>/dev/null || true)
                cfg_success=$(jq -r '.success_threshold // empty' "$routing_config" 2>/dev/null || true)
                cfg_complexity=$(jq -r '.complexity_upgrade // empty' "$routing_config" 2>/dev/null || true)
                [[ -n "$cfg_min" && "$cfg_min" != "null" ]] && min_samples="$cfg_min"
                [[ -n "$cfg_success" && "$cfg_success" != "null" ]] && success_threshold="$cfg_success"
                [[ -n "$cfg_complexity" && "$cfg_complexity" != "null" ]] && complexity_upgrade="$cfg_complexity"
            fi

            # SPRT-inspired evidence check: if enough data, use log-likelihood ratio
            local use_sonnet=false
            local total_samples=$((sonnet_samples + opus_samples))

            if [[ "$total_samples" -ge 10 ]]; then
                # With 10+ data points, use evidence ratio
                # Log-likelihood ratio: ln(P(data|sonnet_good) / P(data|sonnet_bad))
                # Simplified: if sonnet_rate / opus_rate > 0.95, switch to sonnet
                local rate_ratio
                if awk -v or="$opus_rate" 'BEGIN { exit !(or > 0) }' 2>/dev/null; then
                    rate_ratio=$(awk -v sr="$sonnet_rate" -v or="$opus_rate" 'BEGIN { printf "%.3f", sr / or }')
                else
                    rate_ratio="1.0"
                fi

                if [[ "$sonnet_samples" -ge "$min_samples" ]] && \
                   awk -v sr="$sonnet_rate" -v st="$success_threshold" 'BEGIN { exit !(sr >= st) }' 2>/dev/null && \
                   awk -v rr="$rate_ratio" 'BEGIN { exit !(rr >= 0.95) }' 2>/dev/null; then
                    use_sonnet=true
                fi
            elif [[ "$sonnet_samples" -ge "$min_samples" ]] && \
                 awk -v sr="$sonnet_rate" -v st="$success_threshold" 'BEGIN { exit !(sr >= st) }' 2>/dev/null; then
                # Fewer data points — fall back to simple threshold check
                use_sonnet=true
            fi

            if [[ "$use_sonnet" == "true" ]]; then
                if [[ "$budget_remaining" != "" ]] && [[ "$(echo "$budget_remaining < 5" | bc 2>/dev/null || echo "0")" == "1" ]]; then
                    model="haiku"
                    reason="sonnet viable (${sonnet_rate}% success) but budget constrained"
                else
                    model="sonnet"
                    reason="evidence-based: ${sonnet_rate}% success on ${stage} (${sonnet_samples} samples, SPRT)"
                fi
            elif [[ -n "$recommended" && "$recommended" != "null" ]]; then
                model="$recommended"
                reason="historical routing recommendation for ${stage}"
            fi

            # Override: high complexity + critical stage → upgrade to opus if budget allows
            if [[ "$complexity" -ge "$complexity_upgrade" ]]; then
                case "$stage" in
                    plan|design|review|compound_quality)
                        if [[ "$model" != "opus" ]]; then
                            if [[ "$budget_remaining" == "" ]] || [[ "$(echo "$budget_remaining >= 10" | bc 2>/dev/null || echo "1")" == "1" ]]; then
                                model="opus"
                                reason="high complexity (${complexity}/10) overrides historical for critical stage (${stage})"
                            fi
                        fi
                        ;;
                esac
            fi

            local result
            result=$(jq -n --arg model "$model" --arg reason "$reason" --arg stage "$stage" --argjson complexity "$complexity" \
                '{"model": $model, "reason": $reason, "stage": $stage, "complexity": $complexity, "source": "historical"}')

            emit_event "intelligence.model" \
                "stage=$stage" \
                "complexity=$complexity" \
                "model=$model" \
                "source=historical"

            echo "$result"
            return 0
        fi
    fi

    # Strategy 2: Heuristic fallback (no historical data available)
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
        '{"model": $model, "reason": $reason, "stage": $stage, "complexity": $complexity, "source": "heuristic"}')

    emit_event "intelligence.model" \
        "stage=$stage" \
        "complexity=$complexity" \
        "model=$model" \
        "source=heuristic"

    echo "$result"
    return 0
}

# ─── Prediction Validation ─────────────────────────────────────────────────

# intelligence_validate_prediction <issue_id> <predicted_complexity> <actual_iterations> <actual_success>
# Compares predicted complexity to actual outcome for feedback learning.
intelligence_validate_prediction() {
    local issue_id="${1:-}"
    local predicted_complexity="${2:-0}"
    local actual_iterations="${3:-0}"
    local actual_success="${4:-false}"

    if [[ -z "$issue_id" ]]; then
        error "Usage: intelligence_validate_prediction <issue_id> <predicted> <actual_iterations> <actual_success>"
        return 1
    fi

    # Infer actual complexity from iterations (heuristic: map iterations to 1-10 scale)
    local actual_complexity
    if [[ "$actual_iterations" -le 5 ]]; then
        actual_complexity=2
    elif [[ "$actual_iterations" -le 10 ]]; then
        actual_complexity=4
    elif [[ "$actual_iterations" -le 15 ]]; then
        actual_complexity=6
    elif [[ "$actual_iterations" -le 25 ]]; then
        actual_complexity=8
    else
        actual_complexity=10
    fi

    # Calculate prediction error (signed delta)
    local delta=$(( predicted_complexity - actual_complexity ))
    local abs_delta="${delta#-}"

    # Emit prediction error event
    emit_event "intelligence.prediction_error" \
        "issue_id=$issue_id" \
        "predicted=$predicted_complexity" \
        "actual=$actual_complexity" \
        "delta=$delta" \
        "actual_iterations=$actual_iterations" \
        "actual_success=$actual_success"

    # Warn if prediction was significantly off
    if [[ "$abs_delta" -gt 3 ]]; then
        warn "Prediction error for issue #${issue_id}: predicted complexity=${predicted_complexity}, actual~=${actual_complexity} (delta=${delta})"
    fi

    # Update cache entry with actual outcome for future learning
    _intelligence_cache_init

    local validation_file="${HOME}/.shipwright/optimization/prediction-validation.jsonl"
    mkdir -p "${HOME}/.shipwright/optimization"

    local record
    record=$(jq -c -n \
        --arg ts "$(now_iso)" \
        --arg issue "$issue_id" \
        --argjson predicted "$predicted_complexity" \
        --argjson actual "$actual_complexity" \
        --argjson delta "$delta" \
        --argjson iterations "$actual_iterations" \
        --arg success "$actual_success" \
        '{
            ts: $ts,
            issue: $issue,
            predicted_complexity: $predicted,
            actual_complexity: $actual,
            delta: $delta,
            actual_iterations: $iterations,
            actual_success: $success
        }')

    echo "$record" >> "$validation_file"

    # Output summary
    local accuracy_label="good"
    if [[ "$abs_delta" -gt 3 ]]; then
        accuracy_label="poor"
    elif [[ "$abs_delta" -gt 1 ]]; then
        accuracy_label="fair"
    fi

    jq -n \
        --arg issue "$issue_id" \
        --argjson predicted "$predicted_complexity" \
        --argjson actual "$actual_complexity" \
        --argjson delta "$delta" \
        --arg accuracy "$accuracy_label" \
        --arg success "$actual_success" \
        '{
            issue: $issue,
            predicted_complexity: $predicted,
            actual_complexity: $actual,
            delta: $delta,
            accuracy: $accuracy,
            actual_success: $success
        }'
}

# ─── GitHub Enrichment ─────────────────────────────────────────────────────

intelligence_github_enrich() {
    local analysis_json="$1"

    # Skip if GraphQL not available
    type _gh_detect_repo &>/dev/null 2>&1 || { echo "$analysis_json"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "$analysis_json"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "$analysis_json"; return 0; }

    # Get repo context
    local repo_context="{}"
    if type gh_repo_context &>/dev/null 2>&1; then
        repo_context=$(gh_repo_context "$owner" "$repo" 2>/dev/null || echo "{}")
    fi

    # Get security alerts count
    local security_count=0
    if type gh_security_alerts &>/dev/null 2>&1; then
        local alerts
        alerts=$(gh_security_alerts "$owner" "$repo" 2>/dev/null || echo "[]")
        security_count=$(echo "$alerts" | jq 'length' 2>/dev/null || echo "0")
    fi

    # Get dependabot alerts count
    local dependabot_count=0
    if type gh_dependabot_alerts &>/dev/null 2>&1; then
        local deps
        deps=$(gh_dependabot_alerts "$owner" "$repo" 2>/dev/null || echo "[]")
        dependabot_count=$(echo "$deps" | jq 'length' 2>/dev/null || echo "0")
    fi

    # Merge GitHub context into analysis
    echo "$analysis_json" | jq --arg ctx "$repo_context" \
        --argjson sec "${security_count:-0}" \
        --argjson dep "${dependabot_count:-0}" \
        '. + {
            github_context: ($ctx | fromjson? // {}),
            security_alert_count: $sec,
            dependabot_alert_count: $dep
        }' 2>/dev/null || echo "$analysis_json"
}

intelligence_file_risk_score() {
    local file_path="$1"
    local risk_score=0

    type _gh_detect_repo &>/dev/null 2>&1 || { echo "0"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "0"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "0"; return 0; }

    # Factor 1: File churn (high change frequency = higher risk)
    local changes=0
    if type gh_file_change_frequency &>/dev/null 2>&1; then
        changes=$(gh_file_change_frequency "$owner" "$repo" "$file_path" 30 2>/dev/null || echo "0")
    fi
    if [[ "${changes:-0}" -gt 20 ]]; then
        risk_score=$((risk_score + 30))
    elif [[ "${changes:-0}" -gt 10 ]]; then
        risk_score=$((risk_score + 15))
    elif [[ "${changes:-0}" -gt 5 ]]; then
        risk_score=$((risk_score + 5))
    fi

    # Factor 2: Security alerts on this file
    if type gh_security_alerts &>/dev/null 2>&1; then
        local file_alerts
        file_alerts=$(gh_security_alerts "$owner" "$repo" 2>/dev/null | \
            jq --arg path "$file_path" '[.[] | select(.most_recent_instance.location.path == $path)] | length' 2>/dev/null || echo "0")
        [[ "${file_alerts:-0}" -gt 0 ]] && risk_score=$((risk_score + 40))
    fi

    # Factor 3: Many contributors = higher coordination risk
    if type gh_blame_data &>/dev/null 2>&1; then
        local author_count
        author_count=$(gh_blame_data "$owner" "$repo" "$file_path" 2>/dev/null | jq 'length' 2>/dev/null || echo "0")
        [[ "${author_count:-0}" -gt 5 ]] && risk_score=$((risk_score + 10))
    fi

    # Cap at 100
    [[ "$risk_score" -gt 100 ]] && risk_score=100
    echo "$risk_score"
}

intelligence_contributor_expertise() {
    local file_path="$1"

    type _gh_detect_repo &>/dev/null 2>&1 || { echo "[]"; return 0; }
    _gh_detect_repo 2>/dev/null || { echo "[]"; return 0; }

    local owner="${GH_OWNER:-}" repo="${GH_REPO:-}"
    [[ -z "$owner" || -z "$repo" ]] && { echo "[]"; return 0; }

    if type gh_blame_data &>/dev/null 2>&1; then
        gh_blame_data "$owner" "$repo" "$file_path" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
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
    echo -e "  ${CYAN}estimate-iterations${RESET} <analysis>  Estimate build iterations"
    echo -e "  ${CYAN}recommend-model${RESET} <stage> [cplx] Recommend model for stage"
    echo -e "  ${CYAN}cache-stats${RESET}                    Show cache statistics"
    echo -e "  ${CYAN}validate-prediction${RESET} <id> <pred> <iters> <success>  Validate prediction accuracy"
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
        estimate-iterations)
            intelligence_estimate_iterations "$@"
            ;;
        recommend-model)
            intelligence_recommend_model "$@"
            ;;
        validate-prediction)
            intelligence_validate_prediction "$@"
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
