#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright intelligence test — Unit tests for intelligence core        ║
# ║  Mock Claude CLI · Cache behavior · Schema validation · Fallbacks       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLIGENCE_SCRIPT="$SCRIPT_DIR/sw-intelligence.sh"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
YELLOW='\033[38;2;250;204;21m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-intelligence-test.XXXXXX")

    mkdir -p "$TEMP_DIR/.shipwright"
    mkdir -p "$TEMP_DIR/.claude"
    mkdir -p "$TEMP_DIR/project/.claude"
    mkdir -p "$TEMP_DIR/bin"

    export HOME="$TEMP_DIR"
    export EVENTS_FILE="$TEMP_DIR/.shipwright/events.jsonl"
    export NO_GITHUB=true

    # Enable intelligence in mock config
    cat > "$TEMP_DIR/project/.claude/daemon-config.json" <<'DAEMONCFG'
{
  "intelligence": {
    "enabled": true
  }
}
DAEMONCFG

    # Create mock claude binary that returns pre-defined JSON
    cat > "$TEMP_DIR/bin/claude" <<'MOCKBIN'
#!/usr/bin/env bash
# Mock claude CLI — reads MOCK_CLAUDE_RESPONSE env var and outputs it
# Simulates: claude -p "..." (plain text mode, returns raw text/JSON)
if [[ "${1:-}" == "-p" ]] || [[ "${1:-}" == "--print" ]]; then
    if [[ -n "${MOCK_CLAUDE_RESPONSE:-}" ]]; then
        echo "$MOCK_CLAUDE_RESPONSE"
    else
        echo '{"complexity": 5, "risk_level": "medium", "success_probability": 50, "recommended_template": "standard", "key_risks": ["unknown"], "implementation_hints": ["review code"]}'
    fi
    exit 0
fi
echo '{"error": "unexpected args"}'
exit 1
MOCKBIN
    chmod +x "$TEMP_DIR/bin/claude"
    export PATH="$TEMP_DIR/bin:$PATH"
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

reset_test() {
    rm -f "$EVENTS_FILE"
    rm -f "$TEMP_DIR/project/.claude/intelligence-cache.json"
    touch "$EVENTS_FILE"
    # Reset mock response to default analyze response
    export MOCK_CLAUDE_RESPONSE='{"complexity": 5, "risk_level": "medium", "success_probability": 50, "recommended_template": "standard", "key_risks": ["unknown"], "implementation_hints": ["review code"]}'
}

# ═══════════════════════════════════════════════════════════════════════════════
# SOURCE INTELLIGENCE FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

source_intelligence_functions() {
    # Override REPO_DIR so feature flag and cache paths point to our mock project
    export REPO_DIR="$TEMP_DIR/project"

    # Source the intelligence script (it won't run main because BASH_SOURCE != $0)
    source "$INTELLIGENCE_SCRIPT"

    # Re-set paths after sourcing (they get set at script top level)
    REPO_DIR="$TEMP_DIR/project"
    INTELLIGENCE_CACHE="$TEMP_DIR/project/.claude/intelligence-cache.json"
}

# ═══════════════════════════════════════════════════════════════════════════════
# ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════════

assert_equals() {
    local expected="$1" actual="$2" label="${3:-value}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected '$expected', got '$actual' ($label)"
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(echo "$haystack" | head -3)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -qE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $needle ($label)"
    return 1
}

assert_json_key() {
    local json="$1" key="$2" expected="$3" label="${4:-json key}"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    assert_equals "$expected" "$actual" "$label"
}

assert_json_has_key() {
    local json="$1" key="$2" label="${3:-json has key}"
    local has
    has=$(echo "$json" | jq "has(\"$key\")" 2>/dev/null || echo "false")
    if [[ "$has" == "true" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} JSON missing key: $key ($label)"
    return 1
}

assert_json_type() {
    local json="$1" key="$2" expected_type="$3" label="${4:-json type}"
    local actual_type
    actual_type=$(echo "$json" | jq -r ".$key | type" 2>/dev/null || echo "null")
    assert_equals "$expected_type" "$actual_type" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "
    reset_test

    local result=0
    "$test_fn" || result=$?

    if [[ "$result" -eq 0 ]]; then
        echo -e "${GREEN}✓${RESET}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}✗ FAILED${RESET}"
        FAIL=$((FAIL + 1))
        FAILURES+=("$test_name")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. intelligence_analyze_issue returns valid schema
# ──────────────────────────────────────────────────────────────────────────────
test_analyze_issue_schema() {
    export MOCK_CLAUDE_RESPONSE='{"complexity": 7, "risk_level": "high", "success_probability": 65, "recommended_template": "full", "key_risks": ["database migration", "backwards compat"], "implementation_hints": ["add migration script"]}'

    local issue='{"title":"Add user authentication","body":"Implement OAuth2 login flow","labels":["feature","security"]}'
    local result
    result=$(intelligence_analyze_issue "$issue")

    assert_json_has_key "$result" "complexity" "has complexity" &&
    assert_json_has_key "$result" "risk_level" "has risk_level" &&
    assert_json_has_key "$result" "success_probability" "has success_probability" &&
    assert_json_has_key "$result" "recommended_template" "has recommended_template" &&
    assert_json_key "$result" ".complexity" "7" "complexity is 7" &&
    assert_json_key "$result" ".risk_level" "high" "risk_level is high" &&
    assert_json_key "$result" ".recommended_template" "full" "template is full" &&
    assert_json_type "$result" "key_risks" "array" "key_risks is array"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Cache hit on second call with same input
# ──────────────────────────────────────────────────────────────────────────────
test_cache_hit() {
    export MOCK_CLAUDE_RESPONSE='{"complexity": 3, "risk_level": "low", "success_probability": 90, "recommended_template": "fast", "key_risks": [], "implementation_hints": ["simple fix"]}'

    local issue='{"title":"Fix typo in README","body":"Line 42 has a typo","labels":["docs"]}'

    # First call — should hit Claude
    local result1
    result1=$(intelligence_analyze_issue "$issue")

    # Check that no cache_hit event was emitted for first call
    local hits_before=0
    hits_before=$(grep -c "intelligence.cache_hit" "$EVENTS_FILE" 2>/dev/null || true)
    hits_before="${hits_before:-0}"

    # Second call — should hit cache
    local result2
    result2=$(intelligence_analyze_issue "$issue")

    local hits_after=0
    hits_after=$(grep -c "intelligence.cache_hit" "$EVENTS_FILE" 2>/dev/null || true)
    hits_after="${hits_after:-0}"

    assert_equals "$result1" "$result2" "cached result matches original" &&
    assert_equals "1" "$hits_after" "one cache hit event emitted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Graceful degradation when claude binary not available
# ──────────────────────────────────────────────────────────────────────────────
test_graceful_no_claude() {
    # Remove claude from PATH by overriding with a dir that has no claude
    local save_path="$PATH"
    mkdir -p "$TEMP_DIR/empty_bin"
    export PATH="$TEMP_DIR/empty_bin"

    local issue='{"title":"Test issue","body":"Test body","labels":[]}'
    local result
    result=$(intelligence_analyze_issue "$issue")

    # Restore PATH
    export PATH="$save_path"

    # Should return fallback values without crashing
    assert_json_has_key "$result" "complexity" "fallback has complexity" &&
    assert_json_has_key "$result" "risk_level" "fallback has risk_level" &&
    assert_json_key "$result" ".recommended_template" "standard" "fallback template is standard"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. intelligence_compose_pipeline produces valid pipeline JSON
# ──────────────────────────────────────────────────────────────────────────────
test_compose_pipeline_schema() {
    export MOCK_CLAUDE_RESPONSE='{"stages": [{"id": "intake", "enabled": true, "model": "haiku", "config": {}}, {"id": "build", "enabled": true, "model": "sonnet", "config": {"max_iterations": 10}}, {"id": "test", "enabled": true, "model": "sonnet", "config": {}}, {"id": "review", "enabled": true, "model": "opus", "config": {}}, {"id": "pr", "enabled": true, "model": "haiku", "config": {}}], "rationale": "balanced pipeline for medium complexity"}'

    local analysis='{"complexity": 5, "risk_level": "medium"}'
    local ctx='{"language": "typescript", "test_framework": "jest"}'
    local result
    result=$(intelligence_compose_pipeline "$analysis" "$ctx" "50")

    assert_json_type "$result" "stages" "array" "stages is array" &&
    local stage_count
    stage_count=$(echo "$result" | jq '.stages | length')
    assert_equals "5" "$stage_count" "5 stages composed" &&
    local first_id
    first_id=$(echo "$result" | jq -r '.stages[0].id')
    assert_equals "intake" "$first_id" "first stage is intake"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. intelligence_recommend_model returns valid model names
# ──────────────────────────────────────────────────────────────────────────────
test_recommend_model_valid() {
    local result

    # High complexity, critical stage → opus
    result=$(intelligence_recommend_model "plan" 9 100)
    assert_json_key "$result" ".model" "opus" "plan stage + high complexity = opus" &&

    # Low complexity, simple stage → haiku
    result=$(intelligence_recommend_model "intake" 2 100)
    assert_json_key "$result" ".model" "haiku" "intake + low complexity = haiku" &&

    # Medium complexity, build stage → sonnet
    result=$(intelligence_recommend_model "build" 5 100)
    assert_json_key "$result" ".model" "sonnet" "build + medium complexity = sonnet" &&

    # Budget constrained → haiku
    result=$(intelligence_recommend_model "review" 9 3)
    assert_json_key "$result" ".model" "haiku" "budget < 5 = haiku" &&

    # All results should have reason field
    assert_json_has_key "$result" "reason" "has reason field"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. intelligence_predict_cost returns numeric estimates
# ──────────────────────────────────────────────────────────────────────────────
test_predict_cost_schema() {
    export MOCK_CLAUDE_RESPONSE='{"estimated_cost_usd": 8.50, "estimated_iterations": 4, "estimated_tokens": 750000, "likely_failure_stage": "test", "confidence": 65}'

    local analysis='{"complexity": 6, "risk_level": "medium"}'
    local history='{"avg_cost": 7.00, "avg_iterations": 3}'
    local result
    result=$(intelligence_predict_cost "$analysis" "$history")

    assert_json_has_key "$result" "estimated_cost_usd" "has estimated_cost_usd" &&
    assert_json_has_key "$result" "estimated_iterations" "has estimated_iterations" &&

    local cost
    cost=$(echo "$result" | jq -r '.estimated_cost_usd')
    # Verify it's numeric
    if [[ "$cost" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        return 0
    else
        echo -e "    ${RED}✗${RESET} estimated_cost_usd is not numeric: $cost"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Cache TTL expiry
# ──────────────────────────────────────────────────────────────────────────────
test_cache_ttl_expiry() {
    export MOCK_CLAUDE_RESPONSE='{"complexity": 4, "risk_level": "low", "success_probability": 80, "recommended_template": "fast", "key_risks": [], "implementation_hints": []}'

    # Manually write a cache entry with expired timestamp
    local cache_file="$TEMP_DIR/project/.claude/intelligence-cache.json"
    mkdir -p "$(dirname "$cache_file")"
    local old_ts=1000000  # very old timestamp
    local hash
    hash=$(_intelligence_md5 "test_cache_ttl_key")

    cat > "$cache_file" <<CACHE
{
  "entries": {
    "${hash}": {
      "result": {"old": "data"},
      "timestamp": ${old_ts},
      "ttl": 3600
    }
  }
}
CACHE

    # Try to get cached value — should miss because it's expired
    local cached_result=0
    _intelligence_cache_get "test_cache_ttl_key" 3600 >/dev/null 2>&1 || cached_result=$?

    assert_equals "1" "$cached_result" "expired cache returns miss (exit 1)"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. intelligence_search_memory returns ranked results
# ──────────────────────────────────────────────────────────────────────────────
test_search_memory() {
    export MOCK_CLAUDE_RESPONSE='{"results": [{"file": "auth_fix.json", "relevance": 95, "summary": "Fixed OAuth token refresh"}, {"file": "db_migration.json", "relevance": 40, "summary": "Database schema changes"}]}'

    # Create mock memory files
    local mem_dir="$TEMP_DIR/.shipwright/memory/test_repo"
    mkdir -p "$mem_dir"
    echo '{"type": "fix", "issue": "OAuth token expired", "fix": "added refresh logic"}' > "$mem_dir/auth_fix.json"
    echo '{"type": "fix", "issue": "DB migration failed", "fix": "added rollback"}' > "$mem_dir/db_migration.json"

    local result
    result=$(intelligence_search_memory "authentication token refresh" "$mem_dir" 5)

    assert_json_type "$result" "results" "array" "results is array" &&
    local count
    count=$(echo "$result" | jq '.results | length')
    assert_equals "2" "$count" "two results returned" &&

    local top_file
    top_file=$(echo "$result" | jq -r '.results[0].file')
    assert_equals "auth_fix.json" "$top_file" "most relevant file first"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Feature flag disabled returns fallback
# ──────────────────────────────────────────────────────────────────────────────
test_disabled_returns_fallback() {
    # Disable intelligence
    cat > "$TEMP_DIR/project/.claude/daemon-config.json" <<'CFG'
{
  "intelligence": {
    "enabled": false
  }
}
CFG

    local issue='{"title":"Test","body":"Test body","labels":[]}'
    local result
    result=$(intelligence_analyze_issue "$issue")

    assert_json_key "$result" ".error" "intelligence_disabled" "returns intelligence_disabled error" &&
    assert_json_has_key "$result" "complexity" "fallback has complexity" &&
    assert_json_key "$result" ".recommended_template" "standard" "fallback template"

    # Re-enable for other tests
    cat > "$TEMP_DIR/project/.claude/daemon-config.json" <<'CFG'
{
  "intelligence": {
    "enabled": true
  }
}
CFG
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Events are emitted for analysis
# ──────────────────────────────────────────────────────────────────────────────
test_events_emitted() {
    export MOCK_CLAUDE_RESPONSE='{"complexity": 6, "risk_level": "high", "success_probability": 55, "recommended_template": "full", "key_risks": ["data loss"], "implementation_hints": ["backup first"]}'

    local issue='{"title":"Migrate database","body":"Move from SQLite to Postgres","labels":["breaking"]}'
    intelligence_analyze_issue "$issue" >/dev/null

    assert_contains "$(cat "$EVENTS_FILE")" "intelligence.analysis" "analysis event emitted" &&
    assert_contains "$(cat "$EVENTS_FILE")" "complexity" "event has complexity field" &&
    assert_contains "$(cat "$EVENTS_FILE")" "risk_level" "event has risk_level field"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. recommend_model emits events
# ──────────────────────────────────────────────────────────────────────────────
test_recommend_model_events() {
    intelligence_recommend_model "build" 5 100 >/dev/null

    assert_contains "$(cat "$EVENTS_FILE")" "intelligence.model" "model event emitted" &&
    assert_contains "$(cat "$EVENTS_FILE")" "stage" "event has stage field" &&
    assert_contains "$(cat "$EVENTS_FILE")" "model" "event has model field"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Cache init creates file if missing
# ──────────────────────────────────────────────────────────────────────────────
test_cache_init() {
    rm -f "$INTELLIGENCE_CACHE"

    _intelligence_cache_init

    if [[ -f "$INTELLIGENCE_CACHE" ]]; then
        local content
        content=$(cat "$INTELLIGENCE_CACHE")
        assert_contains "$content" "entries" "cache file has entries key"
    else
        echo -e "    ${RED}✗${RESET} Cache file not created"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright intelligence test — Unit Tests                       ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the intelligence script exists
    if [[ ! -f "$INTELLIGENCE_SCRIPT" ]]; then
        echo -e "${RED}✗ Intelligence script not found: $INTELLIGENCE_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    source_intelligence_functions
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_analyze_issue_schema:analyze_issue returns valid schema"
        "test_cache_hit:Cache hit on second call with same input"
        "test_graceful_no_claude:Graceful degradation when claude CLI unavailable"
        "test_compose_pipeline_schema:compose_pipeline produces valid pipeline JSON"
        "test_recommend_model_valid:recommend_model returns valid model names"
        "test_predict_cost_schema:predict_cost returns numeric estimates"
        "test_cache_ttl_expiry:Cache TTL expiry returns miss"
        "test_search_memory:search_memory returns ranked results"
        "test_disabled_returns_fallback:Feature flag disabled returns fallback"
        "test_events_emitted:Events emitted for analysis"
        "test_recommend_model_events:recommend_model emits events"
        "test_cache_init:Cache init creates file if missing"
    )

    for entry in "${tests[@]}"; do
        local fn="${entry%%:*}"
        local desc="${entry#*:}"

        if [[ -n "$filter" && "$fn" != "$filter" ]]; then
            continue
        fi

        run_test "$desc" "$fn"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo -e "${PURPLE}${BOLD}━━━ Results ━━━${RESET}"
    echo -e "  ${GREEN}Passed:${RESET} $PASS"
    echo -e "  ${RED}Failed:${RESET} $FAIL"
    echo -e "  ${DIM}Total:${RESET}  $TOTAL"
    echo ""

    if [[ "$FAIL" -gt 0 ]]; then
        echo -e "${RED}${BOLD}Failed tests:${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
        echo ""
        exit 1
    fi

    echo -e "${GREEN}${BOLD}All $PASS tests passed!${RESET}"
    echo ""
    exit 0
}

main "$@"
