#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker providers test — Unit tests for GitHub, Linear,      ║
# ║  and Jira provider scripts (provider_discover_issues, provider_get_issue,  ║
# ║  provider_create_issue, provider_comment, provider_close_issue, etc.)      ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/test-helpers.sh
source "$SCRIPT_DIR/lib/test-helpers.sh"
# shellcheck source=lib/compat.sh
[[ -f "$SCRIPT_DIR/lib/compat.sh" ]] && source "$SCRIPT_DIR/lib/compat.sh"

# ─── Colors ─────────────────────────────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
PURPLE='\033[38;2;124;58;237m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""
GH_CALLS=""
CURL_CALLS=""

# ═══════════════════════════════════════════════════════════════════════════════
# ENVIRONMENT & MOCKS
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-tracker-providers-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/scripts/lib"

    GH_CALLS="$TEMP_DIR/gh-calls.log"
    CURL_CALLS="$TEMP_DIR/curl-calls.log"
    : > "$GH_CALLS"
    : > "$CURL_CALLS"

    # Copy provider scripts and lib
    cp "$SCRIPT_DIR/sw-tracker-github.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/sw-tracker-linear.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/sw-tracker-jira.sh" "$TEMP_DIR/scripts/"
    [[ -d "$SCRIPT_DIR/lib" ]] && cp -r "$SCRIPT_DIR/lib" "$TEMP_DIR/scripts/"
    if [[ -f "$SCRIPT_DIR/lib/config.sh" ]]; then
        cp "$SCRIPT_DIR/lib/config.sh" "$TEMP_DIR/scripts/lib/"
    fi

    # Link real jq
    ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq" 2>/dev/null || true

    # Mock gh — logs args and returns realistic outputs
    cat > "$TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_CALLS_FILE:-/dev/null}"
case "${1:-}" in
    issue)
        case "${2:-}" in
            list)
                # Realistic gh issue list --json output
                echo '[{"number":42,"title":"Fix bug","labels":[{"name":"bug"}],"state":"OPEN"},{"number":43,"title":"Add feature","labels":[{"name":"enhancement"}],"state":"OPEN"}]'
                ;;
            view)
                # Realistic gh issue view --json output
                echo '{"number":42,"title":"Fix bug","body":"Description here","labels":[{"name":"bug"}],"state":"OPEN"}'
                ;;
            create)
                echo "Created issue owner/repo#99"
                ;;
            comment)
                exit 0
                ;;
            edit)
                exit 0
                ;;
            close)
                exit 0
                ;;
            *)
                echo "{}"
                ;;
        esac
        ;;
    *)
        echo "{}"
        ;;
esac
exit 0
GH_EOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock curl — logs full invocation and returns realistic API responses
    cat > "$TEMP_DIR/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
# Log: full args (includes URL like api.linear.app or atlassian.net)
echo "ARGS: $*" >> "${CURL_CALLS_FILE:-/dev/null}"
for i in $(seq 1 $#); do
    eval "arg=\${$i}"
    if [[ "$arg" == "-d" && $((i+1)) -le $# ]]; then
        eval "payload=\${$((i+1))}"
        echo "PAYLOAD: $payload" >> "${CURL_CALLS_FILE:-/dev/null}" 2>/dev/null || true
        break
    fi
done
# Linear GraphQL response — check payload for query type
payload=""
for i in $(seq 1 $#); do
    eval "arg=\${$i}"
    if [[ "$arg" == "-d" && $((i+1)) -le $# ]]; then
        eval "payload=\${$((i+1))}"
        break
    fi
done
if echo "$*" | grep -q "api.linear.app"; then
    if echo "$payload" | grep -q "issue(id:" 2>/dev/null; then
        echo '{"data":{"issue":{"id":"linear-1","title":"Linear issue","description":"Body","labels":{"nodes":[{"name":"bug"}]},"state":{"name":"Started"}}}}'
    elif echo "$payload" | grep -q "issueCreate" 2>/dev/null; then
        echo '{"data":{"issueCreate":{"issue":{"id":"linear-new-123"}}}}'
    else
        echo '{"data":{"team":{"issues":{"nodes":[{"id":"linear-1","title":"Linear issue","labels":{"nodes":[{"name":"bug"}]},"state":{"name":"Started"}}]}}}}'
    fi
elif echo "$*" | grep -q "atlassian.net\|jira"; then
    if echo "$*" | grep -q "statuses"; then
        echo '[{"statuses":[{"name":"In Progress","statusCategory":{"key":"indeterminate"}},{"name":"Done","statusCategory":{"key":"done"}}]}]'
    elif echo "$*" | grep -q "search"; then
        echo '{"issues":[{"key":"PROJ-1","fields":{"summary":"Jira issue","labels":[{"name":"bug"}],"status":{"name":"In Progress"}}}]}'
    elif echo "$*" | grep -q "transitions"; then
        echo '{"transitions":[{"id":"1","name":"Done"}]}'
    elif echo "$*" | grep -q "issue/"; then
        echo '{"key":"PROJ-1","fields":{"summary":"Jira issue","description":"Body","labels":[{"name":"bug"}],"status":{"name":"In Progress"}}}'
    elif echo "$*" | grep -q "rest/api/3/issue" && ! echo "$*" | grep -q "issue/PROJ\|issue/[A-Z]"; then
        echo '{"key":"PROJ-99","id":"12345"}'
    else
        echo '{"key":"PROJ-1","fields":{"summary":"Jira issue","description":"Body"}}'
    fi
fi
exit 0
CURL_EOF
    chmod +x "$TEMP_DIR/bin/curl"

    export HOME="$TEMP_DIR/home"
    export PATH="$TEMP_DIR/bin:$PATH"
    export GH_CALLS_FILE="$GH_CALLS"
    export CURL_CALLS_FILE="$CURL_CALLS"
    export SCRIPT_DIR="$TEMP_DIR/scripts"
    unset NO_GITHUB  # Allow gh to run for GitHub provider tests
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

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

# ═══════════════════════════════════════════════════════════════════════════════
# GITHUB PROVIDER TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_github_sources_and_exports() {
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        type provider_discover_issues >/dev/null 2>&1 || return 1
        type provider_get_issue >/dev/null 2>&1 || return 1
        type provider_get_issue_body >/dev/null 2>&1 || return 1
        type provider_create_issue >/dev/null 2>&1 || return 1
        type provider_comment >/dev/null 2>&1 || return 1
        type provider_close_issue >/dev/null 2>&1 || return 1
        type provider_add_label >/dev/null 2>&1 || return 1
    )
}

test_github_provider_discover_calls_gh_list() {
    : > "$GH_CALLS"
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        provider_discover_issues "bug" "open" 25 2>/dev/null >/dev/null || true
    )
    grep -q "issue list" "$GH_CALLS" || return 1
    grep -q "open" "$GH_CALLS" || return 1
    grep -q "25" "$GH_CALLS" || return 1
    grep -q "bug" "$GH_CALLS" || return 1
    grep -q "number,title,labels,state" "$GH_CALLS" || return 1
}

test_github_provider_get_issue_calls_gh_view() {
    : > "$GH_CALLS"
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        provider_get_issue "42" 2>/dev/null >/dev/null || true
    )
    grep -q "issue view" "$GH_CALLS" || return 1
    grep -q "42" "$GH_CALLS" || return 1
}

test_github_provider_create_calls_gh_create() {
    : > "$GH_CALLS"
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        provider_create_issue "New Issue" "Body text" "label1,label2" 2>/dev/null >/dev/null || true
    )
    grep -q "issue create" "$GH_CALLS" || return 1
    grep -q "New Issue" "$GH_CALLS" || return 1
    grep -q "Body text" "$GH_CALLS" || return 1
    grep -q "label1" "$GH_CALLS" || return 1
    grep -q "label2" "$GH_CALLS" || return 1
}

test_github_provider_discover_parses_json() {
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-github.sh" && provider_discover_issues "" "open" 10 2>/dev/null) || true
    echo "$result" | jq -e 'length >= 1' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0] | has("id") and has("title") and has("labels") and has("state")' >/dev/null 2>&1 || return 1
    local id
    id=$(echo "$result" | jq -r '.[0].id')
    [[ "$id" == "42" ]] || return 1
}

test_github_provider_get_issue_parses_json() {
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-github.sh" && provider_get_issue "42" 2>/dev/null) || true
    echo "$result" | jq -e '.id == 42' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.title == "Fix bug"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.body == "Description here"' >/dev/null 2>&1 || return 1
}

test_github_provider_create_parses_response() {
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-github.sh" && provider_create_issue "Test" "Body" 2>/dev/null) || true
    echo "$result" | jq -e 'has("id") and has("title")' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.title == "Test"' >/dev/null 2>&1 || return 1
}

test_github_no_github_returns_empty() {
    local result
    result=$(cd "$TEMP_DIR" && export NO_GITHUB=1 && source "$SCRIPT_DIR/sw-tracker-github.sh" && provider_discover_issues "x" "open" 5 2>/dev/null) || true
    [[ -z "$result" || "$result" == "[]" ]] || return 1
}

test_github_provider_comment_calls_gh() {
    : > "$GH_CALLS"
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        provider_comment "42" "My comment" 2>/dev/null || true
    )
    grep -q "issue comment" "$GH_CALLS" || return 1
}

test_github_provider_close_calls_gh() {
    : > "$GH_CALLS"
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-github.sh"
        provider_close_issue "42" 2>/dev/null || true
    )
    grep -q "issue close" "$GH_CALLS" || return 1
}

test_github_provider_get_issue_body_calls_gh() {
    : > "$GH_CALLS"
    (cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-github.sh" && provider_get_issue_body "42" 2>/dev/null) >/dev/null || true
    grep -q "issue view" "$GH_CALLS" || return 1
}

test_jira_provider_comment_uses_api() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    (cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-jira.sh" && provider_comment "PROJ-1" "Test comment" 2>/dev/null) >/dev/null || true
    grep -q "comment" "$CURL_CALLS" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# LINEAR PROVIDER TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_linear_sources_and_exports() {
    mkdir -p "$TEMP_DIR/home/.shipwright"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_test","team_id":"tid"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-linear.sh"
        type provider_discover_issues >/dev/null 2>&1 || return 1
        type provider_get_issue >/dev/null 2>&1 || return 1
        type provider_create_issue >/dev/null 2>&1 || return 1
        type provider_comment >/dev/null 2>&1 || return 1
        type provider_close_issue >/dev/null 2>&1 || return 1
    )
}

test_linear_provider_discover_uses_curl() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_key","team_id":"team-123"}}
EOF
    (cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-linear.sh" && provider_discover_issues "" "open" 50 2>/dev/null) >/dev/null || true
    grep -q "api.linear.app" "$CURL_CALLS" || return 1
}

test_linear_provider_discover_parses_response() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_key","team_id":"team-123"}}
EOF
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-linear.sh" && provider_discover_issues "" "open" 50 2>/dev/null) || true
    echo "$result" | jq -e 'length >= 0' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].id == "linear-1" and .[0].title == "Linear issue"' >/dev/null 2>&1 || return 1
}

test_linear_provider_get_issue_uses_curl() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_key","team_id":"team-123"}}
EOF
    (cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-linear.sh" && provider_get_issue "linear-1" 2>/dev/null) >/dev/null || true
    grep -q "api.linear.app" "$CURL_CALLS" || return 1
}

test_linear_provider_get_issue_parses_response() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_key","team_id":"team-123"}}
EOF
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-linear.sh" && provider_get_issue "linear-1" 2>/dev/null) || true
    [[ -n "$result" ]] || return 1
    echo "$result" | jq -e '.' >/dev/null 2>&1 || return 1
}

test_linear_graphql_query_construction() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"linear":{"api_key":"lin_key","team_id":"team-123"}}
EOF
    (cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-linear.sh" && provider_discover_issues "bug" "open" 10 2>/dev/null) >/dev/null || true
    # Linear GraphQL: curl args include URL and -d for POST body
    local content
    content=$(cat "$CURL_CALLS" 2>/dev/null)
    [[ -n "$content" ]] || return 1
    # ARGS line has -d and graphql URL
    echo "$content" | grep -qF -- "-d" || return 1
    echo "$content" | grep -q "graphql" || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# JIRA PROVIDER TESTS
# ═══════════════════════════════════════════════════════════════════════════════

test_jira_sources_and_exports() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"tok","project_key":"PROJ"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-jira.sh"
        type provider_discover_issues >/dev/null 2>&1 || return 1
        type provider_get_issue >/dev/null 2>&1 || return 1
        type provider_create_issue >/dev/null 2>&1 || return 1
        type provider_comment >/dev/null 2>&1 || return 1
        type provider_close_issue >/dev/null 2>&1 || return 1
    )
}

test_jira_provider_uses_curl() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://myteam.atlassian.net","email":"u@x.com","api_token":"t","project_key":"PRJ"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-jira.sh"
        provider_discover_issues "" "open" 20 2>/dev/null >/dev/null || true
    )
    grep -q "atlassian.net\|jira" "$CURL_CALLS" || return 1
}

test_jira_url_construction() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://mycompany.atlassian.net","email":"u@x.com","api_token":"t","project_key":"ABC"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-jira.sh"
        provider_discover_issues "" "open" 5 2>/dev/null >/dev/null || true
    )
    grep -q "rest/api/3" "$CURL_CALLS" || return 1
    grep -q "search" "$CURL_CALLS" || return 1
}

test_jira_provider_discover_parses_response() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-jira.sh" && provider_discover_issues "" "open" 10 2>/dev/null) || true
    echo "$result" | jq -e 'length >= 0' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.[0].id == "PROJ-1" and .[0].title == "Jira issue"' >/dev/null 2>&1 || return 1
}

test_jira_provider_get_issue_uses_rest_api() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-jira.sh"
        provider_get_issue "PROJ-1" 2>/dev/null >/dev/null || true
    )
    grep -q "issue/PROJ-1" "$CURL_CALLS" || return 1
}

test_jira_provider_get_issue_parses_response() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-jira.sh" && provider_get_issue "PROJ-1" 2>/dev/null) || true
    echo "$result" | jq -e '.id == "PROJ-1"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.title == "Jira issue"' >/dev/null 2>&1 || return 1
}

test_jira_provider_create_uses_post() {
    : > "$CURL_CALLS"
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    (
        cd "$TEMP_DIR"
        source "$SCRIPT_DIR/sw-tracker-jira.sh"
        provider_create_issue "New task" "Description" 2>/dev/null >/dev/null || true
    )
    grep -q "rest/api/3" "$CURL_CALLS" || return 1
}

test_jira_provider_create_parses_response() {
    cat > "$TEMP_DIR/home/.shipwright/tracker-config.json" <<'EOF'
{"jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"t","project_key":"PROJ"}}
EOF
    local result
    result=$(cd "$TEMP_DIR" && source "$SCRIPT_DIR/sw-tracker-jira.sh" && provider_create_issue "New task" "Desc" 2>/dev/null) || true
    echo "$result" | jq -e '.id == "PROJ-99"' >/dev/null 2>&1 || return 1
    echo "$result" | jq -e '.title == "New task"' >/dev/null 2>&1 || return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    echo ""
    echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║  shipwright tracker providers — Test Suite (26 tests)      ║${RESET}"
    echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    echo ""

    echo -e "${PURPLE}${BOLD}GitHub Provider${RESET}"
    run_test "GitHub sources correctly and exports expected functions" test_github_sources_and_exports
    run_test "provider_discover_issues calls gh issue list with correct args" test_github_provider_discover_calls_gh_list
    run_test "provider_get_issue calls gh issue view" test_github_provider_get_issue_calls_gh_view
    run_test "provider_create_issue calls gh issue create" test_github_provider_create_calls_gh_create
    run_test "provider_discover_issues parses gh JSON output" test_github_provider_discover_parses_json
    run_test "provider_get_issue parses gh JSON output" test_github_provider_get_issue_parses_json
    run_test "provider_create_issue parses gh response" test_github_provider_create_parses_response
    run_test "NO_GITHUB=1 returns empty for discover" test_github_no_github_returns_empty
    run_test "provider_comment calls gh issue comment" test_github_provider_comment_calls_gh
    run_test "provider_close_issue calls gh issue close" test_github_provider_close_calls_gh
    run_test "provider_get_issue_body calls gh issue view" test_github_provider_get_issue_body_calls_gh
    echo ""

    echo -e "${PURPLE}${BOLD}Linear Provider${RESET}"
    run_test "Linear sources correctly and exports expected functions" test_linear_sources_and_exports
    run_test "provider_discover_issues uses curl to Linear GraphQL API" test_linear_provider_discover_uses_curl
    run_test "provider_discover_issues parses Linear API response" test_linear_provider_discover_parses_response
    run_test "provider_get_issue uses curl" test_linear_provider_get_issue_uses_curl
    run_test "provider_get_issue parses response" test_linear_provider_get_issue_parses_response
    run_test "Linear query construction includes team and issues" test_linear_graphql_query_construction
    echo ""

    echo -e "${PURPLE}${BOLD}Jira Provider${RESET}"
    run_test "Jira sources correctly and exports expected functions" test_jira_sources_and_exports
    run_test "provider_discover_issues uses curl to Jira REST API" test_jira_provider_uses_curl
    run_test "Jira URL construction uses JIRA_BASE_URL and rest/api/3" test_jira_url_construction
    run_test "provider_discover_issues parses Jira response" test_jira_provider_discover_parses_response
    run_test "provider_get_issue uses issue/KEY endpoint" test_jira_provider_get_issue_uses_rest_api
    run_test "provider_get_issue parses Jira response" test_jira_provider_get_issue_parses_response
    run_test "provider_create_issue uses POST to REST API" test_jira_provider_create_uses_post
    run_test "provider_create_issue parses response" test_jira_provider_create_parses_response
    run_test "provider_comment uses Jira comment API" test_jira_provider_comment_uses_api
    echo ""

    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    if [[ "$FAIL" -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
    else
        echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
        for f in "${FAILURES[@]}"; do
            echo -e "  ${RED}✗${RESET} $f"
        done
    fi
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${RESET}"
    echo ""
    exit "$FAIL"
}

main "$@"
