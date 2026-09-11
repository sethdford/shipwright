#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright github-graphql test — Unit tests for GitHub GraphQL client  ║
# ║  Mock gh CLI · Cache behavior · Error handling · Repo detection        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
GRAPHQL_SCRIPT="$SCRIPT_DIR/sw-github-graphql.sh"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
# shellcheck disable=SC2034

# ─── Counters ─────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════════
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEST_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-github-graphql-test.XXXXXX")

    mkdir -p "$TEST_TEMP_DIR/.shipwright/github-cache"
    mkdir -p "$TEST_TEMP_DIR/.claude"
    mkdir -p "$TEST_TEMP_DIR/project/.git"
    mkdir -p "$TEST_TEMP_DIR/bin"

    export HOME="$TEST_TEMP_DIR"
    export EVENTS_FILE="$TEST_TEMP_DIR/.shipwright/events.jsonl"
    touch "$EVENTS_FILE"

    # IMPORTANT: Do NOT set NO_GITHUB=true here — we need functions to proceed
    # past the _gh_graphql_available check. Instead, we mock `gh`.
    export NO_GITHUB=false

    # Create mock gh binary
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKBIN'
#!/usr/bin/env bash
# Mock gh CLI — reads MOCK_GH_RESPONSE env var
# Supports: gh api graphql, gh api <path>, gh auth status

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
    echo "Logged in to github.com"
    exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
    if [[ -n "${MOCK_GH_RESPONSE:-}" ]]; then
        echo "$MOCK_GH_RESPONSE"
    else
        echo '{"data": {}}'
    fi
    exit "${MOCK_GH_EXIT_CODE:-0}"
fi

if [[ "${1:-}" == "api" ]]; then
    local_path="${2:-}"
    # Check if there is a path-specific mock
    local_mock_var="MOCK_GH_API_$(echo "$local_path" | tr '/' '_' | tr '?' '_' | tr '&' '_' | tr '=' '_' | tr '-' '_' | tr '.' '_' | head -c 80)"
    local_mock_val="${!local_mock_var:-}"
    if [[ -n "$local_mock_val" ]]; then
        echo "$local_mock_val"
        exit 0
    fi
    if [[ -n "${MOCK_GH_RESPONSE:-}" ]]; then
        echo "$MOCK_GH_RESPONSE"
    else
        echo '[]'
    fi
    exit "${MOCK_GH_EXIT_CODE:-0}"
fi

echo '{"error": "unexpected gh args: '"$*"'"}'
exit 1
MOCKBIN
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Create mock git binary
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKGIT'
#!/usr/bin/env bash
if [[ "${1:-}" == "remote" && "${2:-}" == "get-url" ]]; then
    echo "${MOCK_GIT_REMOTE:-git@github.com:testowner/testrepo.git}"
    exit 0
fi
# Pass through for other git commands
/usr/bin/git "$@"
MOCKGIT
    chmod +x "$TEST_TEMP_DIR/bin/git"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
}

cleanup_env() {
    if [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}
trap cleanup_env EXIT

reset_test() {
    rm -f "$EVENTS_FILE"
    touch "$EVENTS_FILE"
    rm -f "$TEST_TEMP_DIR/.shipwright/github-cache"/*.json 2>/dev/null || true
    export MOCK_GH_RESPONSE=""
    export MOCK_GH_EXIT_CODE=0
    export NO_GITHUB=false
    # Reset repo detection
    GH_OWNER=""
    GH_REPO=""
}

# ═══════════════════════════════════════════════════════════════════════════════
# SOURCE GRAPHQL FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

source_graphql_functions() {
    export REPO_DIR="$TEST_TEMP_DIR/project"
    # shellcheck disable=SC1090
    source "$GRAPHQL_SCRIPT"
    REPO_DIR="$TEST_TEMP_DIR/project"
    GH_CACHE_DIR="$TEST_TEMP_DIR/.shipwright/github-cache"
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
    if printf '%s\n' "$haystack" | grep -E "$needle" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(echo "$haystack" | head -3)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -E "$needle" >/dev/null 2>&1; then
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

assert_file_exists() {
    local path="$1" label="${2:-file exists}"
    if [[ -f "$path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $path ($label)"
    return 1
}

assert_file_not_exists() {
    local path="$1" label="${2:-file not exists}"
    if [[ ! -f "$path" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File unexpectedly exists: $path ($label)"
    return 1
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
# 1. Fresh cache returns cached data
# ──────────────────────────────────────────────────────────────────────────────
test_cache_fresh_hit() {
    local cache_key="test_cache_hit"
    local test_data='{"data": "cached_value"}'
    _gh_cache_set "$cache_key" "$test_data"

    local result
    result=$(_gh_cache_get "$cache_key" "3600") || {
        echo -e "    ${RED}✗${RESET} Cache get failed for fresh entry"
        return 1
    }

    assert_json_key "$result" ".data" "cached_value" "cached data"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Stale cache misses
# ──────────────────────────────────────────────────────────────────────────────
test_cache_stale_miss() {
    local cache_key="test_cache_stale"
    local cache_file="${GH_CACHE_DIR}/${cache_key}.json"

    # Write cache file
    _gh_cache_set "$cache_key" '{"data": "old"}'

    # Backdate the file to make it stale (2 hours ago)
    if [[ "$(uname)" == "Darwin" ]]; then
        touch -t "$(date -v-2H +%Y%m%d%H%M.%S)" "$cache_file"
    else
        touch -d "2 hours ago" "$cache_file"
    fi

    # TTL of 60 seconds should make it stale
    local result
    result=$(_gh_cache_get "$cache_key" "60" 2>/dev/null) && {
        echo -e "    ${RED}✗${RESET} Expected cache miss but got hit"
        return 1
    }

    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Atomic writes — no partial files
# ──────────────────────────────────────────────────────────────────────────────
test_cache_atomic_write() {
    local cache_key="test_atomic"
    local data='{"key": "value"}'

    _gh_cache_set "$cache_key" "$data"

    # Verify no .tmp files linger
    local tmp_count=0
    for f in "$GH_CACHE_DIR"/*.tmp.*; do
        [[ -f "$f" ]] && tmp_count=$((tmp_count + 1))
    done

    assert_equals "0" "$tmp_count" "no leftover tmp files" &&
    assert_file_exists "${GH_CACHE_DIR}/${cache_key}.json" "cache file written"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. gh_file_change_frequency returns count from mock
# ──────────────────────────────────────────────────────────────────────────────
test_file_change_frequency() {
    export MOCK_GH_RESPONSE='{"data": {"repository": {"defaultBranchRef": {"target": {"history": {"totalCount": 42}}}}}}'

    local result
    result=$(gh_file_change_frequency "testowner" "testrepo" "src/main.ts" "30")

    assert_equals "42" "$result" "commit count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. gh_contributors returns parsed contributor list
# ──────────────────────────────────────────────────────────────────────────────
test_contributors() {
    export MOCK_GH_RESPONSE='[{"login": "alice", "contributions": 150}, {"login": "bob", "contributions": 75}]'

    local result
    result=$(gh_contributors "testowner" "testrepo")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "2" "$count" "contributor count" &&
    assert_json_key "$result" '.[0].login' "alice" "first contributor" &&
    assert_json_key "$result" '.[1].contributions' "75" "second contributions"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. gh_similar_issues truncates search text
# ──────────────────────────────────────────────────────────────────────────────
test_similar_issues_truncation() {
    export MOCK_GH_RESPONSE='{"data": {"search": {"nodes": [{"number": 1, "title": "Test issue", "closedAt": "2026-01-15T00:00:00Z", "labels": {"nodes": [{"name": "bug"}]}}]}}}'

    # Long search text (> 100 chars)
    local long_text="This is a very long search text that exceeds the one hundred character limit imposed by the GitHub search API to prevent excessively broad queries"

    local result
    result=$(gh_similar_issues "testowner" "testrepo" "$long_text" "5")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "1" "$count" "issue count" &&
    assert_json_key "$result" '.[0].number' "1" "issue number" &&
    assert_json_key "$result" '.[0].title' "Test issue" "issue title"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. gh_branch_protection handles 404 gracefully
# ──────────────────────────────────────────────────────────────────────────────
test_branch_protection_404() {
    export MOCK_GH_EXIT_CODE=1  # gh api returns non-zero on 404

    local result
    result=$(gh_branch_protection "testowner" "testrepo" "main")

    assert_json_key "$result" '.protected' "false" "not protected"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. gh_security_alerts handles 403 (not enabled)
# ──────────────────────────────────────────────────────────────────────────────
test_security_alerts_403() {
    export MOCK_GH_EXIT_CODE=1  # Simulates 403

    local result
    result=$(gh_security_alerts "testowner" "testrepo")

    assert_equals "[]" "$result" "empty array on 403"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. gh_dependabot_alerts handles 403
# ──────────────────────────────────────────────────────────────────────────────
test_dependabot_alerts_403() {
    export MOCK_GH_EXIT_CODE=1  # Simulates 403

    local result
    result=$(gh_dependabot_alerts "testowner" "testrepo")

    assert_equals "[]" "$result" "empty array on 403"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. gh_repo_context aggregates multiple queries
# ──────────────────────────────────────────────────────────────────────────────
test_repo_context_aggregates() {
    # Mock will return different data for different API endpoints
    # Since our mock returns the same MOCK_GH_RESPONSE for all calls,
    # we need a simple response that works as both contributor list and alerts
    export MOCK_GH_RESPONSE='[]'

    local result
    result=$(gh_repo_context "testowner" "testrepo" 2>/dev/null)

    assert_json_has_key "$result" "owner" "has owner" &&
    assert_json_has_key "$result" "repo" "has repo" &&
    assert_json_has_key "$result" "contributor_count" "has contributor_count" &&
    assert_json_has_key "$result" "security_alert_count" "has security_alert_count" &&
    assert_json_has_key "$result" "dependabot_alert_count" "has dependabot_alert_count" &&
    assert_json_has_key "$result" "branch_protection" "has branch_protection" &&
    assert_json_key "$result" '.owner' "testowner" "correct owner" &&
    assert_json_key "$result" '.repo' "testrepo" "correct repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. NO_GITHUB: all functions return early
# ──────────────────────────────────────────────────────────────────────────────
test_no_github_returns_early() {
    export NO_GITHUB=true

    local freq contributors issues history protection security dependabot actions

    freq=$(gh_file_change_frequency "o" "r" "p" "30")
    contributors=$(gh_contributors "o" "r")
    issues=$(gh_similar_issues "o" "r" "test" "5")
    history=$(gh_commit_history "o" "r" "p" "10")
    protection=$(gh_branch_protection "o" "r" "main")
    security=$(gh_security_alerts "o" "r")
    dependabot=$(gh_dependabot_alerts "o" "r")
    actions=$(gh_actions_runs "o" "r" "ci.yml" "5")

    assert_equals "0" "$freq" "freq returns 0" &&
    assert_equals "[]" "$contributors" "contributors returns []" &&
    assert_equals "[]" "$issues" "issues returns []" &&
    assert_equals "[]" "$history" "history returns []" &&
    assert_json_key "$protection" '.protected' "false" "protection returns unprotected" &&
    assert_equals "[]" "$security" "security returns []" &&
    assert_equals "[]" "$dependabot" "dependabot returns []" &&
    assert_equals "[]" "$actions" "actions returns []"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. _gh_detect_repo: parses SSH URL
# ──────────────────────────────────────────────────────────────────────────────
test_detect_repo_ssh() {
    export MOCK_GIT_REMOTE="git@github.com:myorg/myrepo.git"
    GH_OWNER=""
    GH_REPO=""

    _gh_detect_repo

    assert_equals "myorg" "$GH_OWNER" "SSH owner" &&
    assert_equals "myrepo" "$GH_REPO" "SSH repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. _gh_detect_repo: parses HTTPS URL
# ──────────────────────────────────────────────────────────────────────────────
test_detect_repo_https() {
    export MOCK_GIT_REMOTE="https://github.com/another-org/another-repo.git"
    GH_OWNER=""
    GH_REPO=""

    _gh_detect_repo

    assert_equals "another-org" "$GH_OWNER" "HTTPS owner" &&
    assert_equals "another-repo" "$GH_REPO" "HTTPS repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. _gh_detect_repo: parses HTTPS URL without .git suffix
# ──────────────────────────────────────────────────────────────────────────────
test_detect_repo_https_no_git() {
    export MOCK_GIT_REMOTE="https://github.com/org/repo"
    GH_OWNER=""
    GH_REPO=""

    _gh_detect_repo

    assert_equals "org" "$GH_OWNER" "HTTPS no-git owner" &&
    assert_equals "repo" "$GH_REPO" "HTTPS no-git repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. gh_codeowners: parses CODEOWNERS file
# ──────────────────────────────────────────────────────────────────────────────
test_codeowners_parse() {
    # Base64 encoded CODEOWNERS content:
    # *.ts @team/frontend
    # /api/ @team/backend @alice
    local codeowners_content
    codeowners_content=$(printf '*.ts @team/frontend\n/api/ @team/backend @alice\n' | base64)

    # Mock gh api to return the base64 content (simulating contents API with --jq)
    export MOCK_GH_RESPONSE="$codeowners_content"

    local result
    result=$(gh_codeowners "testowner" "testrepo")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "2" "$count" "codeowner entry count" &&
    assert_json_key "$result" '.[0].pattern' "*.ts" "first pattern" &&
    assert_json_key "$result" '.[0].owners[0]' "@team/frontend" "first owner" &&
    assert_json_key "$result" '.[1].pattern' "/api/" "second pattern"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Cache clear removes all files
# ──────────────────────────────────────────────────────────────────────────────
test_cache_clear() {
    # Create some cache files
    _gh_cache_set "file1" '{"a": 1}'
    _gh_cache_set "file2" '{"b": 2}'

    assert_file_exists "${GH_CACHE_DIR}/file1.json" "file1 before clear"
    assert_file_exists "${GH_CACHE_DIR}/file2.json" "file2 before clear"

    _gh_cache_clear >/dev/null 2>&1

    assert_file_not_exists "${GH_CACHE_DIR}/file1.json" "file1 after clear" &&
    assert_file_not_exists "${GH_CACHE_DIR}/file2.json" "file2 after clear"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. gh_commit_history returns parsed commits
# ──────────────────────────────────────────────────────────────────────────────
test_commit_history() {
    export MOCK_GH_RESPONSE='[{"sha": "abc1234567890", "commit": {"message": "Fix bug\n\nDetailed description", "author": {"name": "alice", "date": "2026-02-10T12:00:00Z"}}}]'

    local result
    result=$(gh_commit_history "testowner" "testrepo" "src/main.ts" "10")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "1" "$count" "commit count" &&
    assert_json_key "$result" '.[0].sha' "abc1234" "short sha" &&
    assert_json_key "$result" '.[0].message' "Fix bug" "first line only" &&
    assert_json_key "$result" '.[0].author' "alice" "author"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. gh_blame_data returns aggregated author data
# ──────────────────────────────────────────────────────────────────────────────
test_blame_data() {
    export MOCK_GH_RESPONSE='[
        {"commit": {"author": {"name": "alice", "date": "2026-02-10T12:00:00Z"}}},
        {"commit": {"author": {"name": "alice", "date": "2026-02-09T12:00:00Z"}}},
        {"commit": {"author": {"name": "bob", "date": "2026-02-08T12:00:00Z"}}}
    ]'

    local result
    result=$(gh_blame_data "testowner" "testrepo" "src/main.ts")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "2" "$count" "unique authors" &&
    assert_json_key "$result" '.[0].author' "alice" "top author" &&
    assert_json_key "$result" '.[0].commits' "2" "alice commit count"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. gh_actions_runs returns parsed runs
# ──────────────────────────────────────────────────────────────────────────────
test_actions_runs() {
    export MOCK_GH_RESPONSE='{"workflow_runs": [{"id": 123, "conclusion": "success", "created_at": "2026-02-10T12:00:00Z", "updated_at": "2026-02-10T12:05:00Z"}]}'

    local result
    result=$(gh_actions_runs "testowner" "testrepo" "ci.yml" "5")

    local count
    count=$(echo "$result" | jq 'length' 2>/dev/null)

    assert_equals "1" "$count" "run count" &&
    assert_json_key "$result" '.[0].id' "123" "run id" &&
    assert_json_key "$result" '.[0].conclusion' "success" "conclusion" &&
    assert_json_key "$result" '.[0].duration_seconds' "300" "duration 5 min"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Events emitted for cache operations
# ──────────────────────────────────────────────────────────────────────────────
test_events_emitted() {
    export MOCK_GH_RESPONSE='[{"login": "alice", "contributions": 10}]'

    # First call — cache miss
    gh_contributors "testowner" "testrepo" >/dev/null

    local miss_count=0
    miss_count=$(grep -c "github.cache_miss" "$EVENTS_FILE" || true)
    miss_count="${miss_count:-0}"

    # Second call — cache hit
    gh_contributors "testowner" "testrepo" >/dev/null

    local hit_count=0
    hit_count=$(grep -c "github.cache_hit" "$EVENTS_FILE" || true)
    hit_count="${hit_count:-0}"

    [[ "$miss_count" -ge 1 ]] && [[ "$hit_count" -ge 1 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}━━━ shipwright github-graphql tests ━━━${RESET}"
    echo ""

    setup_env
    source_graphql_functions

    local tests=(
        "test_cache_fresh_hit:Fresh cache returns cached data"
        "test_cache_stale_miss:Stale cache returns miss"
        "test_cache_atomic_write:Atomic writes leave no temp files"
        "test_file_change_frequency:gh_file_change_frequency returns count"
        "test_contributors:gh_contributors returns parsed list"
        "test_similar_issues_truncation:gh_similar_issues truncates long text"
        "test_branch_protection_404:gh_branch_protection handles 404"
        "test_security_alerts_403:gh_security_alerts handles 403"
        "test_dependabot_alerts_403:gh_dependabot_alerts handles 403"
        "test_repo_context_aggregates:gh_repo_context aggregates data"
        "test_no_github_returns_early:NO_GITHUB returns defaults"
        "test_detect_repo_ssh:_gh_detect_repo parses SSH URL"
        "test_detect_repo_https:_gh_detect_repo parses HTTPS URL"
        "test_detect_repo_https_no_git:_gh_detect_repo parses HTTPS without .git"
        "test_codeowners_parse:gh_codeowners parses CODEOWNERS file"
        "test_cache_clear:Cache clear removes all files"
        "test_commit_history:gh_commit_history returns parsed commits"
        "test_blame_data:gh_blame_data aggregates authors"
        "test_actions_runs:gh_actions_runs calculates duration"
        "test_events_emitted:Events emitted for cache hit/miss"
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
