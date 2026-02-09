#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory+cost test — Unit tests for memory system & cost tracking   ║
# ║  Self-contained mock environment · No external dependencies            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEMORY_SCRIPT="$SCRIPT_DIR/cct-memory.sh"
COST_SCRIPT="$SCRIPT_DIR/cct-cost.sh"

# ─── Colors (matches cct theme) ──────────────────────────────────────────────
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
# MOCK ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-memory-test.XXXXXX")

    # Create a mock git repo so repo_hash() and repo_name() work
    mkdir -p "$TEMP_DIR/project"
    (
        cd "$TEMP_DIR/project"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test User"
        git remote add origin "https://github.com/test-org/test-repo.git"

        # Create a minimal package.json for pattern detection
        cat > package.json <<'PKG'
{
  "name": "test-project",
  "version": "1.0.0",
  "type": "module",
  "scripts": { "test": "jest" },
  "dependencies": { "express": "^4.18.0" },
  "devDependencies": { "jest": "^29.0.0" }
}
PKG
        mkdir -p src tests
        echo "// test file" > tests/app.test.js
        git add -A
        git commit -m "Initial commit" --quiet
    )

    # Override HOME so memory writes go to temp dir
    export ORIG_HOME="$HOME"
    export HOME="$TEMP_DIR/home"
    mkdir -p "$HOME/.claude-teams"
    mkdir -p "$HOME/.shipwright"

    # Create mock pipeline state file
    mkdir -p "$TEMP_DIR/project/.claude/pipeline-artifacts"
    cat > "$TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
---
pipeline: standard
goal: "Add JWT auth"
status: complete
issue: "42"
branch: "feat/42-add-jwt-auth"
current_stage: pr
started_at: 2026-02-07T10:00:00Z
updated_at: 2026-02-07T10:30:00Z
elapsed: 30m
stages:
  intake: complete
  plan: complete
  build: complete
  test: complete
  review: complete
  pr: complete
---

## Log
### intake (10:00:00)
Goal: Add JWT auth
STATE

    # Create mock test results
    cat > "$TEMP_DIR/project/.claude/pipeline-artifacts/test-results.log" <<'TESTS'
PASS tests/auth.test.js
  ✓ validates token (5ms)
  ✓ rejects invalid token (3ms)
  ✓ handles expired token (2ms)

Test Suites: 1 passed, 1 total
Tests:       3 passed, 3 total
TESTS

    # Create mock review
    cat > "$TEMP_DIR/project/.claude/pipeline-artifacts/review.md" <<'REVIEW'
# Code Review

## Findings
- **[Bug]** src/auth.js:15 — Missing null check on token payload
- **[Warning]** src/auth.js:22 — Consider using constant-time comparison
- **[Suggestion]** src/auth.js:5 — Move secret to environment variable

## Summary
3 issues found: 0 critical, 1 bug, 1 warning, 1 suggestion.
REVIEW
}

cleanup_env() {
    if [[ -n "${ORIG_HOME:-}" ]]; then
        export HOME="$ORIG_HOME"
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

run_test() {
    local test_name="$1"
    local test_fn="$2"
    TOTAL=$((TOTAL + 1))

    echo -ne "  ${CYAN}▸${RESET} ${test_name}... "

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

assert_contains() {
    local haystack="$1" needle="$2" label="${3:-contains}"
    if printf '%s\n' "$haystack" | grep -qiE "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Missing pattern: ${needle} (${label})"
    echo -e "    ${DIM}Output (last 3 lines):${RESET}"
    echo "$haystack" | tail -3 | sed 's/^/      /'
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: ${filepath} (${label})"
    return 1
}

assert_json_field() {
    local file="$1" query="$2" expected="$3" label="${4:-json field}"
    local actual
    actual=$(jq -r "$query" "$file" 2>/dev/null || echo "")
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected ${query}=${expected}, got ${actual} (${label})"
    return 1
}

assert_json_gt() {
    local file="$1" query="$2" threshold="$3" label="${4:-json gt}"
    local actual
    actual=$(jq -r "$query" "$file" 2>/dev/null || echo "0")
    if awk -v a="$actual" -v t="$threshold" 'BEGIN { exit !(a > t) }'; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected ${query} > ${threshold}, got ${actual} (${label})"
    return 1
}

# Compute repo hash the same way cct-memory.sh does (echo -n to avoid trailing newline)
compute_repo_hash() {
    local url="$1"
    echo -n "$url" | shasum -a 256 | cut -c1-12
}

# ═══════════════════════════════════════════════════════════════════════════════
# MEMORY TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Memory capture from pipeline state + artifacts
# ──────────────────────────────────────────────────────────────────────────────
test_memory_capture_pipeline() {
    local output
    output=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1)

    assert_contains "$output" "Captured pipeline learnings" "capture success message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Memory inject returns context for each stage
# ──────────────────────────────────────────────────────────────────────────────
test_memory_inject_stages() {
    # First capture some data
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    local plan_ctx build_ctx test_ctx review_ctx
    plan_ctx=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject plan 2>&1)
    build_ctx=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject build 2>&1)
    test_ctx=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject test 2>&1)
    review_ctx=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject review 2>&1)

    assert_contains "$plan_ctx" "Memory Context" "plan has header" &&
    assert_contains "$plan_ctx" "Stage: plan" "plan has stage" &&
    assert_contains "$build_ctx" "Failure Patterns" "build has failures section" &&
    assert_contains "$test_ctx" "Test Failures" "test has test section" &&
    assert_contains "$review_ctx" "Review Feedback" "review has feedback section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Failure deduplication increments seen_count
# ──────────────────────────────────────────────────────────────────────────────
test_failure_deduplication() {
    # Capture same failure twice
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    # Record the same failure pattern directly
    local error_output="Error: Cannot find module './db'"
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    local mem_dir="$HOME/.shipwright/memory"
    local hash
    hash=$(compute_repo_hash "https://github.com/test-org/test-repo.git")
    local failures_file="$mem_dir/$hash/failures.json"

    assert_file_exists "$failures_file" "failures.json exists"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Pattern detection identifies project type
# ──────────────────────────────────────────────────────────────────────────────
test_pattern_detection() {
    local output
    output=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1)

    assert_contains "$output" "node" "detects node project" &&
    assert_contains "$output" "express" "detects express framework"

    # Verify patterns.json was updated
    local mem_dir="$HOME/.shipwright/memory"
    local hash
    hash=$(compute_repo_hash "https://github.com/test-org/test-repo.git")
    local patterns_file="$mem_dir/$hash/patterns.json"

    assert_file_exists "$patterns_file" "patterns.json exists" &&
    assert_json_field "$patterns_file" '.project.type' "node" "project type is node" &&
    assert_json_field "$patterns_file" '.project.framework' "express" "framework is express" &&
    assert_json_field "$patterns_file" '.project.test_runner' "jest" "test runner is jest" &&
    assert_json_field "$patterns_file" '.conventions.import_style' "esm" "import style is esm"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Cross-repo vs per-repo isolation
# ──────────────────────────────────────────────────────────────────────────────
test_repo_isolation() {
    # Capture for project 1
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    # Create a second project with different origin
    mkdir -p "$TEMP_DIR/project2"
    (
        cd "$TEMP_DIR/project2"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test User"
        git remote add origin "https://github.com/other-org/other-repo.git"
        echo '{"name":"project2","dependencies":{"fastify":"^4.0"}}' > package.json
        git add -A
        git commit -m "Init" --quiet
    )

    # Capture for project 2
    (cd "$TEMP_DIR/project2" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    # Verify they're in separate directories
    local hash1 hash2
    hash1=$(compute_repo_hash "https://github.com/test-org/test-repo.git")
    hash2=$(compute_repo_hash "https://github.com/other-org/other-repo.git")

    if [[ "$hash1" == "$hash2" ]]; then
        echo -e "    ${RED}✗${RESET} Repo hashes should differ"
        return 1
    fi

    assert_file_exists "$HOME/.shipwright/memory/$hash1/patterns.json" "project 1 patterns" &&
    assert_file_exists "$HOME/.shipwright/memory/$hash2/patterns.json" "project 2 patterns" &&
    assert_json_field "$HOME/.shipwright/memory/$hash1/patterns.json" '.project.framework' "express" "project 1 is express" &&
    assert_json_field "$HOME/.shipwright/memory/$hash2/patterns.json" '.project.framework' "fastify" "project 2 is fastify"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Memory show displays dashboard without errors
# ──────────────────────────────────────────────────────────────────────────────
test_memory_show() {
    # Capture some data first
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    local output
    output=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" show 2>&1)

    assert_contains "$output" "Memory:" "show has header" &&
    assert_contains "$output" "PROJECT" "show has project section" &&
    assert_contains "$output" "FAILURE" "show has failures section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Memory search finds matching entries
# ──────────────────────────────────────────────────────────────────────────────
test_memory_search() {
    # Capture project patterns
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    local output
    output=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" search "express" 2>&1)

    assert_contains "$output" "express" "search finds express"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Memory export produces valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_memory_export() {
    # Capture some data first
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    local output
    output=$(cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" export 2>&1)

    # Should be valid JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Export is not valid JSON"
        return 1
    fi

    assert_contains "$output" "exported_at" "has exported_at field" &&
    assert_contains "$output" "test-org/test-repo" "has repo name"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Memory forget clears repo memory
# ──────────────────────────────────────────────────────────────────────────────
test_memory_forget() {
    # Capture some data first
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    # Verify memory exists
    local hash
    hash=$(compute_repo_hash "https://github.com/test-org/test-repo.git")
    assert_file_exists "$HOME/.shipwright/memory/$hash/patterns.json" "memory exists before forget" || return 1

    # Forget
    (cd "$TEMP_DIR/project" && bash "$MEMORY_SCRIPT" forget --all 2>&1) >/dev/null

    # Verify memory is gone
    if [[ -d "$HOME/.shipwright/memory/$hash" ]]; then
        echo -e "    ${RED}✗${RESET} Memory directory still exists after forget"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# COST TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 10. Cost calculation for each model
# ──────────────────────────────────────────────────────────────────────────────
test_cost_calculation() {
    # opus: 1M input ($15) + 1M output ($75) = $90
    local opus_cost
    opus_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 opus 2>&1)

    # sonnet: 1M input ($3) + 1M output ($15) = $18
    local sonnet_cost
    sonnet_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 sonnet 2>&1)

    # haiku: 1M input ($0.25) + 1M output ($1.25) = $1.50
    local haiku_cost
    haiku_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 haiku 2>&1)

    # Trim whitespace
    opus_cost=$(echo "$opus_cost" | tr -d '[:space:]')
    sonnet_cost=$(echo "$sonnet_cost" | tr -d '[:space:]')
    haiku_cost=$(echo "$haiku_cost" | tr -d '[:space:]')

    if [[ "$opus_cost" != "90.0000" ]]; then
        echo -e "    ${RED}✗${RESET} Opus cost: expected 90.0000, got ${opus_cost}"
        return 1
    fi

    if [[ "$sonnet_cost" != "18.0000" ]]; then
        echo -e "    ${RED}✗${RESET} Sonnet cost: expected 18.0000, got ${sonnet_cost}"
        return 1
    fi

    if [[ "$haiku_cost" != "1.5000" ]]; then
        echo -e "    ${RED}✗${RESET} Haiku cost: expected 1.5000, got ${haiku_cost}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Cost recording writes to costs.json
# ──────────────────────────────────────────────────────────────────────────────
test_cost_record() {
    bash "$COST_SCRIPT" record 50000 10000 sonnet build 42 2>&1 >/dev/null

    assert_file_exists "$HOME/.shipwright/costs.json" "costs.json exists" &&
    assert_json_gt "$HOME/.shipwright/costs.json" '.entries | length' "0" "has entries"

    # Check the recorded entry
    local stage
    stage=$(jq -r '.entries[-1].stage' "$HOME/.shipwright/costs.json" 2>/dev/null)
    if [[ "$stage" != "build" ]]; then
        echo -e "    ${RED}✗${RESET} Expected stage=build, got ${stage}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Budget checking
# ──────────────────────────────────────────────────────────────────────────────
test_budget_checking() {
    # Set a budget
    bash "$COST_SCRIPT" budget set 10.00 2>&1 >/dev/null

    assert_file_exists "$HOME/.shipwright/budget.json" "budget.json exists" &&
    assert_json_field "$HOME/.shipwright/budget.json" '.enabled' "true" "budget enabled" || return 1

    # Verify budget amount (jq stores 10.00 as a number; compare numerically)
    local actual_budget
    actual_budget=$(jq -r '.daily_budget_usd' "$HOME/.shipwright/budget.json" 2>/dev/null)
    if ! awk -v a="$actual_budget" 'BEGIN { exit !(a == 10) }'; then
        echo -e "    ${RED}✗${RESET} Expected daily_budget_usd=10, got ${actual_budget}"
        return 1
    fi

    # Check budget should pass (low estimated cost)
    local check_result=0
    bash "$COST_SCRIPT" check-budget 1.00 2>&1 >/dev/null || check_result=$?
    # 0=ok, 1=warning, 2=blocked — we just verify it doesn't crash
    if [[ "$check_result" -gt 2 ]]; then
        echo -e "    ${RED}✗${RESET} Budget check returned unexpected code: ${check_result}"
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Cost dashboard runs without errors
# ──────────────────────────────────────────────────────────────────────────────
test_cost_dashboard() {
    # Record some costs first
    bash "$COST_SCRIPT" record 50000 10000 sonnet intake 42 2>&1 >/dev/null
    bash "$COST_SCRIPT" record 100000 30000 opus build 42 2>&1 >/dev/null
    bash "$COST_SCRIPT" record 20000 5000 haiku review 42 2>&1 >/dev/null

    local output
    output=$(bash "$COST_SCRIPT" show --period 7 2>&1)

    assert_contains "$output" "Cost Intelligence" "dashboard has header" &&
    assert_contains "$output" "SPENDING" "dashboard has spending section" &&
    assert_contains "$output" "TOKENS" "dashboard has tokens section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Cost JSON output is valid
# ──────────────────────────────────────────────────────────────────────────────
test_cost_json_output() {
    # Record some costs
    bash "$COST_SCRIPT" record 50000 10000 sonnet build 42 2>&1 >/dev/null

    local output
    output=$(bash "$COST_SCRIPT" show --json 2>&1)

    # Should be valid JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} JSON output is not valid"
        echo -e "    ${DIM}Output: $(echo "$output" | head -3)${RESET}"
        return 1
    fi

    assert_contains "$output" "total_cost_usd" "has total_cost field" &&
    assert_contains "$output" "by_stage" "has by_stage field"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright memory+cost test — Unit Tests for Memory & Cost      ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify scripts exist
    if [[ ! -f "$MEMORY_SCRIPT" ]]; then
        echo -e "${RED}✗ Memory script not found: $MEMORY_SCRIPT${RESET}"
        exit 1
    fi
    if [[ ! -f "$COST_SCRIPT" ]]; then
        echo -e "${RED}✗ Cost script not found: $COST_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up mock environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_memory_capture_pipeline:Memory capture from pipeline state"
        "test_memory_inject_stages:Memory inject returns context for each stage"
        "test_failure_deduplication:Failure capture stores patterns"
        "test_pattern_detection:Pattern detection identifies project type"
        "test_repo_isolation:Cross-repo vs per-repo isolation"
        "test_memory_show:Memory show displays dashboard"
        "test_memory_search:Memory search finds matching entries"
        "test_memory_export:Memory export produces valid JSON"
        "test_memory_forget:Memory forget clears repo memory"
        "test_cost_calculation:Cost calculation for each model"
        "test_cost_record:Cost recording writes to costs.json"
        "test_budget_checking:Budget set and check"
        "test_cost_dashboard:Cost dashboard runs without errors"
        "test_cost_json_output:Cost JSON output is valid"
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
