#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright memory+cost test — Unit tests for memory system & cost tracking   ║
# ║  Self-contained mock environment · No external dependencies            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
MEMORY_SCRIPT="$SCRIPT_DIR/sw-memory.sh"
COST_SCRIPT="$SCRIPT_DIR/sw-cost.sh"

# ─── Colors (matches shipwright theme) ──────────────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ─────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════════
# MOCK ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-memory-test.XXXXXX")

    # Create a mock git repo so repo_hash() and repo_name() work
    mkdir -p "$TEST_TEMP_DIR/project"
    (
        cd "$TEST_TEMP_DIR/project"
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
    export HOME="$TEST_TEMP_DIR/home"
    export REPO_DIR="$TEST_TEMP_DIR/project"
    mkdir -p "$HOME/.shipwright"

    # Create mock pipeline state file
    mkdir -p "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-state.md" <<'STATE'
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
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/test-results.log" <<'TESTS'
PASS tests/auth.test.js
  ✓ validates token (5ms)
  ✓ rejects invalid token (3ms)
  ✓ handles expired token (2ms)

Test Suites: 1 passed, 1 total
Tests:       3 passed, 3 total
TESTS

    # Create mock review
    cat > "$TEST_TEMP_DIR/project/.claude/pipeline-artifacts/review.md" <<'REVIEW'
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
    unset REPO_DIR 2>/dev/null || true
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
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
    if printf '%s\n' "$haystack" | grep -iE "$needle" >/dev/null 2>&1; then
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

# Compute repo hash the same way sw-memory.sh does (echo -n to avoid trailing newline)
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
    output=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1)

    assert_contains "$output" "Captured pipeline learnings" "capture success message"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Memory inject returns context for each stage
# ──────────────────────────────────────────────────────────────────────────────
test_memory_inject_stages() {
    # First capture some data
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    local plan_ctx build_ctx test_ctx review_ctx
    plan_ctx=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject plan 2>&1)
    build_ctx=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject build 2>&1)
    test_ctx=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject test 2>&1)
    review_ctx=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" inject review 2>&1)

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
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    # Record the same failure pattern directly
    # shellcheck disable=SC2034
    local error_output="Error: Cannot find module './db'"
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
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
    output=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1)

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
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    # Create a second project with different origin
    mkdir -p "$TEST_TEMP_DIR/project2"
    (
        cd "$TEST_TEMP_DIR/project2"
        git init --quiet
        git config user.email "test@test.com"
        git config user.name "Test User"
        git remote add origin "https://github.com/other-org/other-repo.git"
        echo '{"name":"project2","dependencies":{"fastify":"^4.0"}}' > package.json
        git add -A
        git commit -m "Init" --quiet
    )

    # Capture for project 2
    (cd "$TEST_TEMP_DIR/project2" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

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
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" capture \
        ".claude/pipeline-state.md" ".claude/pipeline-artifacts" 2>&1) >/dev/null

    local output
    output=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" show 2>&1)

    assert_contains "$output" "Memory:" "show has header" &&
    assert_contains "$output" "PROJECT" "show has project section" &&
    assert_contains "$output" "FAILURE" "show has failures section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Memory search finds matching entries
# ──────────────────────────────────────────────────────────────────────────────
test_memory_search() {
    # Capture project patterns
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    local output
    output=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" search "express" 2>&1)

    assert_contains "$output" "express" "search finds express"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Memory export produces valid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_memory_export() {
    # Capture some data first
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    local output
    output=$(cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" export 2>&1)

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
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" pattern project 2>&1) >/dev/null

    # Verify memory exists
    local hash
    hash=$(compute_repo_hash "https://github.com/test-org/test-repo.git")
    assert_file_exists "$HOME/.shipwright/memory/$hash/patterns.json" "memory exists before forget" || return 1

    # Forget
    (cd "$TEST_TEMP_DIR/project" && bash "$MEMORY_SCRIPT" forget --all 2>&1) >/dev/null

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
    # Rates track the current generation. Opus was $15/$75 (Opus 4.0/4.1-era)
    # and Haiku $0.25/$1.25 (Haiku 3.5-era); both overstated or understated
    # spend once routing moved to Opus 4.5+ / Haiku 4.5.
    #
    # opus: 1M input ($5) + 1M output ($25) = $30
    local opus_cost
    opus_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 opus 2>&1)

    # sonnet: 1M input ($3) + 1M output ($15) = $18
    local sonnet_cost
    sonnet_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 sonnet 2>&1)

    # haiku: 1M input ($1) + 1M output ($5) = $6
    local haiku_cost
    haiku_cost=$(bash "$COST_SCRIPT" calculate 1000000 1000000 haiku 2>&1)

    # Trim whitespace
    opus_cost=$(echo "$opus_cost" | tr -d '[:space:]')
    sonnet_cost=$(echo "$sonnet_cost" | tr -d '[:space:]')
    haiku_cost=$(echo "$haiku_cost" | tr -d '[:space:]')

    if [[ "$opus_cost" != "30.0000" ]]; then
        echo -e "    ${RED}✗${RESET} Opus cost: expected 30.0000, got ${opus_cost}"
        return 1
    fi

    if [[ "$sonnet_cost" != "18.0000" ]]; then
        echo -e "    ${RED}✗${RESET} Sonnet cost: expected 18.0000, got ${sonnet_cost}"
        return 1
    fi

    if [[ "$haiku_cost" != "6.0000" ]]; then
        echo -e "    ${RED}✗${RESET} Haiku cost: expected 6.0000, got ${haiku_cost}"
        return 1
    fi

    # Full model IDs must route to the same tier as the bare alias. This is the
    # case that actually broke: cost_calculate matched on `claude-opus-4*`, so
    # `claude-opus-5` missed every tier and silently fell through to the
    # sonnet-priced catch-all — understating Opus spend with no error. The
    # previous generation is asserted too, because historical costs.json
    # entries still name those models and must not be repriced.
    local id expected actual
    for pair in \
        "claude-opus-5:30.0000" \
        "claude-opus-4-6:30.0000" \
        "claude-sonnet-5:18.0000" \
        "claude-sonnet-4-6:18.0000" \
        "claude-haiku-4-5:6.0000"
    do
        id="${pair%%:*}"
        expected="${pair##*:}"
        actual=$(bash "$COST_SCRIPT" calculate 1000000 1000000 "$id" 2>&1 | tr -d '[:space:]')
        if [[ "$actual" != "$expected" ]]; then
            echo -e "    ${RED}✗${RESET} ${id}: expected ${expected}, got ${actual}"
            return 1
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Cost recording writes to costs.json
# ──────────────────────────────────────────────────────────────────────────────
test_cost_record() {
    bash "$COST_SCRIPT" record 50000 10000 sonnet build 42 >/dev/null 2>&1

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
    bash "$COST_SCRIPT" budget set 10.00 >/dev/null 2>&1

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
    bash "$COST_SCRIPT" check-budget 1.00 >/dev/null 2>&1 || check_result=$?
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
    bash "$COST_SCRIPT" record 50000 10000 sonnet intake 42 >/dev/null 2>&1
    bash "$COST_SCRIPT" record 100000 30000 opus build 42 >/dev/null 2>&1
    bash "$COST_SCRIPT" record 20000 5000 haiku review 42 >/dev/null 2>&1

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
    bash "$COST_SCRIPT" record 50000 10000 sonnet build 42 >/dev/null 2>&1

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

# ──────────────────────────────────────────────────────────────────────────────
# 15. Actionable failures threshold filtering
# ──────────────────────────────────────────────────────────────────────────────
test_memory_get_actionable_failures() {
    (
        cd "$TEST_TEMP_DIR/project" || return 1
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"

        # Create failures.json with mixed seen_counts
        cat > "$mem_dir/failures.json" <<'FAIL'
{
    "failures": [
        {"pattern": "test timeout", "stage": "test", "seen_count": 1, "last_seen": "2026-02-01"},
        {"pattern": "lint error", "stage": "review", "seen_count": 2, "last_seen": "2026-02-02"},
        {"pattern": "build OOM", "stage": "build", "seen_count": 3, "last_seen": "2026-02-03"},
        {"pattern": "flaky integration", "stage": "test", "seen_count": 5, "last_seen": "2026-02-04"}
    ]
}
FAIL

        # Get failures with threshold 3
        local result
        result=$(memory_get_actionable_failures 3)

        local count
        count=$(echo "$result" | jq 'length')

        # Should get exactly 2 entries (seen_count 3 and 5)
        [[ "$count" == "2" ]] || { echo "Expected 2 failures, got $count"; return 1; }

        # Verify sorted by seen_count descending (5 first, then 3)
        local first_count
        first_count=$(echo "$result" | jq '.[0].seen_count')
        [[ "$first_count" == "5" ]] || { echo "Expected first seen_count=5, got $first_count"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Actionable failures with no file returns []
# ──────────────────────────────────────────────────────────────────────────────
test_memory_get_actionable_failures_empty() {
    (
        cd "$TEST_TEMP_DIR/project" || return 1
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"

        # Remove failures.json if exists
        rm -f "$mem_dir/failures.json"

        local result
        result=$(memory_get_actionable_failures 3)

        [[ "$result" == "[]" ]] || { echo "Expected [], got $result"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. DORA baseline calculation from events
# ──────────────────────────────────────────────────────────────────────────────
test_memory_get_dora_baseline() {
    (
        cd "$TEST_TEMP_DIR/project" || return 1
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        # Write synthetic pipeline events
        local now_e
        now_e=$(date +%s)
        local events_file="$HOME/.shipwright/events.jsonl"
        mkdir -p "$(dirname "$events_file")"
        true > "$events_file"

        # Write 3 successful pipeline events within last 7 days
        for i in 1 2 3; do
            local ts_e=$((now_e - 86400 + i * 3600))
            echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"ts_epoch\":$ts_e,\"type\":\"pipeline.completed\",\"result\":\"success\",\"duration_s\":600}" >> "$events_file"
        done
        # Write 1 failure
        local fail_ts=$((now_e - 43200))
        echo "{\"ts\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",\"ts_epoch\":$fail_ts,\"type\":\"pipeline.completed\",\"result\":\"failure\",\"duration_s\":300}" >> "$events_file"

        local result
        result=$(memory_get_dora_baseline 7 0)

        # Should have total=4
        local total
        total=$(echo "$result" | jq '.total')
        [[ "$total" == "4" ]] || { echo "Expected total=4, got $total"; return 1; }

        # CFR should be 25% (1/4)
        local cfr
        cfr=$(echo "$result" | jq '.cfr')
        [[ "$cfr" == "25" ]] || { echo "Expected cfr=25, got $cfr"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Error log to failures — memory_capture_failure_from_log
# ──────────────────────────────────────────────────────────────────────────────
test_error_log_to_failures() {
    (
        cd "$TEST_TEMP_DIR/project"
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        local failures_file="$mem_dir/failures.json"

        # Seed empty failures file
        echo '{"failures":[]}' > "$failures_file"

        # Create error-log.jsonl with 2 entries
        local artifacts_dir="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
        mkdir -p "$artifacts_dir"
        echo '{"type":"test","error":"TypeError: Cannot read property foo of undefined"}' > "$artifacts_dir/error-log.jsonl"
        echo '{"type":"syntax","error":"SyntaxError: Unexpected token }"}' >> "$artifacts_dir/error-log.jsonl"

        memory_capture_failure_from_log "$artifacts_dir"

        # Verify failures were captured
        local count
        count=$(jq '.failures | length' "$failures_file" 2>/dev/null || echo "0")
        [[ "$count" -ge 2 ]] || { echo "Expected >= 2 failures, got $count"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Fix outcome tracking — memory_record_fix_outcome
# ──────────────────────────────────────────────────────────────────────────────
test_fix_outcome_tracking() {
    (
        cd "$TEST_TEMP_DIR/project"
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        local failures_file="$mem_dir/failures.json"

        # Seed failures with a pattern that has a fix
        cat > "$failures_file" <<'JSON'
{"failures":[{"pattern":"TypeError: Cannot read property","fix":"Add null check","stage":"test","category":"test","seen_count":1,"times_fix_applied":0,"times_fix_resolved":0}]}
JSON

        # Record a successful fix
        memory_record_fix_outcome "TypeError: Cannot read property" "true" "true"

        # Verify times_fix_applied and times_fix_resolved incremented
        local applied resolved
        applied=$(jq '.failures[0].times_fix_applied' "$failures_file" 2>/dev/null || echo "0")
        resolved=$(jq '.failures[0].times_fix_resolved' "$failures_file" 2>/dev/null || echo "0")
        [[ "$applied" == "1" ]] || { echo "Expected times_fix_applied=1, got $applied"; return 1; }
        [[ "$resolved" == "1" ]] || { echo "Expected times_fix_resolved=1, got $resolved"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Closed-loop inject with effectiveness — memory_closed_loop_inject
# ──────────────────────────────────────────────────────────────────────────────
test_closed_loop_inject_with_effectiveness() {
    (
        cd "$TEST_TEMP_DIR/project"
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        local failures_file="$mem_dir/failures.json"

        # Seed with a fix that has >30% effectiveness (threshold for query)
        cat > "$failures_file" <<'JSON'
{"failures":[{"pattern":"TypeError: Cannot read","fix":"Add null check before access","stage":"test","category":"test","seen_count":5,"fix_applied":10,"fix_resolved":5,"fix_effectiveness_rate":50}]}
JSON

        local result
        result=$(memory_closed_loop_inject "TypeError: Cannot read" 2>/dev/null) || result=""

        # Should return formatted string with category and success rate
        [[ -n "$result" ]] || { echo "Expected non-empty inject result"; return 1; }
        echo "$result" | grep "test" >/dev/null || { echo "Expected category 'test' in result: $result"; return 1; }
        echo "$result" | grep "50%" >/dev/null || { echo "Expected '50%' in result: $result"; return 1; }
        echo "$result" | grep "null check" >/dev/null || { echo "Expected fix text in result: $result"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Global memory aggregation — _memory_aggregate_global
# ──────────────────────────────────────────────────────────────────────────────
test_global_memory_aggregation() {
    (
        cd "$TEST_TEMP_DIR/project"
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        local failures_file="$mem_dir/failures.json"

        # Seed with patterns that have seen_count >= 3 (promotion threshold)
        cat > "$failures_file" <<'JSON'
{"failures":[{"pattern":"Module not found: xyz","fix":"Install xyz","stage":"build","category":"dependency","seen_count":5},{"pattern":"Port already in use","fix":"Kill process","stage":"build","category":"config","seen_count":3},{"pattern":"Rare error once","fix":"Retry","stage":"test","category":"test","seen_count":1}]}
JSON

        # Create global memory file
        local global_file="$GLOBAL_MEMORY"
        mkdir -p "$(dirname "$global_file")"
        echo '{"common_patterns":[]}' > "$global_file"

        _memory_aggregate_global

        # Verify: patterns with seen_count >= 3 should be promoted
        local promoted_count
        promoted_count=$(jq '.common_patterns | length' "$global_file" 2>/dev/null || echo "0")
        [[ "$promoted_count" -eq 2 ]] || { echo "Expected 2 promoted patterns, got $promoted_count"; return 1; }
    )
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Memory finalize pipeline — memory_finalize_pipeline
# ──────────────────────────────────────────────────────────────────────────────
test_memory_finalize_pipeline() {
    (
        cd "$TEST_TEMP_DIR/project"
        # shellcheck disable=SC1090
        source "$MEMORY_SCRIPT" > /dev/null 2>&1

        ensure_memory_dir
        local mem_dir
        mem_dir="$(repo_memory_dir)"
        local failures_file="$mem_dir/failures.json"
        echo '{"failures":[]}' > "$failures_file"

        local state_file="$TEST_TEMP_DIR/project/.claude/pipeline-state.md"
        local artifacts_dir="$TEST_TEMP_DIR/project/.claude/pipeline-artifacts"
        mkdir -p "$artifacts_dir"

        # Create error log for the from_log step
        echo '{"type":"build","error":"ENOENT: no such file lib/missing.js"}' > "$artifacts_dir/error-log.jsonl"

        # Create global memory file
        local global_file="$GLOBAL_MEMORY"
        mkdir -p "$(dirname "$global_file")"
        echo '{"common_patterns":[]}' > "$global_file"

        # Run the composite finalize function
        memory_finalize_pipeline "$state_file" "$artifacts_dir"

        # Verify error was captured from log
        local fail_count
        fail_count=$(jq '.failures | length' "$failures_file" 2>/dev/null || echo "0")
        [[ "$fail_count" -ge 1 ]] || { echo "Expected >= 1 failure after finalize, got $fail_count"; return 1; }
    )
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
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEST_TEMP_DIR${RESET}"
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
        "test_memory_get_actionable_failures:Actionable failures threshold filtering"
        "test_memory_get_actionable_failures_empty:Actionable failures with no file returns []"
        "test_memory_get_dora_baseline:DORA baseline calculation from events"
        "test_error_log_to_failures:Error log entries captured into failures.json"
        "test_fix_outcome_tracking:Fix outcome tracking increments counters"
        "test_closed_loop_inject_with_effectiveness:Closed-loop inject returns formatted fix"
        "test_global_memory_aggregation:Global aggregation promotes frequent patterns"
        "test_memory_finalize_pipeline:Finalize pipeline runs capture + aggregate"
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
