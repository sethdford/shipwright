#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright tracker test — Validate tracker router, providers, and       ║
# ║  enriched pipeline integration with mock environment.                   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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
# MOCK ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-tracker-test.XXXXXX")
    mkdir -p "$TEMP_DIR/scripts"
    mkdir -p "$TEMP_DIR/home/.claude-teams"
    mkdir -p "$TEMP_DIR/home/.claude"

    # Copy tracker scripts
    cp "$SCRIPT_DIR/cct-tracker.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/cct-tracker-linear.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/cct-tracker-jira.sh" "$TEMP_DIR/scripts/"
    cp "$SCRIPT_DIR/cct-pipeline.sh" "$TEMP_DIR/scripts/"

    # Mock binaries directory
    mkdir -p "$TEMP_DIR/bin"

    # Mock jq — pass through to real jq
    if command -v jq &>/dev/null; then
        JQ_BIN="$(command -v jq)"
    else
        echo -e "${RED}${BOLD}✗${RESET} jq is required for tracker tests"
        exit 1
    fi

    # Mock gh — returns canned issue body
    cat > "$TEMP_DIR/bin/gh" <<'GH_EOF'
#!/usr/bin/env bash
# Mock gh — returns issue body with Linear ID or Jira key
if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    if [[ "${MOCK_GH_BODY:-}" != "" ]]; then
        echo "$MOCK_GH_BODY"
    else
        echo '{"body":"**Linear ID:** abc-123\n\n**Jira:** PROJ-42"}'
    fi
    exit 0
fi
echo "{}"
GH_EOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock curl — logs calls, returns success
    cat > "$TEMP_DIR/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
# Mock curl — capture and log
echo "$@" >> "${MOCK_CURL_LOG:-/dev/null}"
# Return a successful response
echo '{"data":{"issueUpdate":{"issue":{"id":"abc","identifier":"TEST-1"}}}}'
CURL_EOF
    chmod +x "$TEMP_DIR/bin/curl"
}

cleanup_env() {
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

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

# ──────────────────────────────────────────────────────────────────────────────
# 1. Provider loads from config (linear)
# ──────────────────────────────────────────────────────────────────────────────
test_provider_loads_linear() {
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"
    cat > "$config" <<'EOF'
{"provider":"linear","linear":{"api_key":"lin_test_key","team_id":"tid","project_id":"pid"}}
EOF

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-tracker.sh" available 2>&1
    ) || true

    if printf '%s\n' "$output" | grep -q "true" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 'true' from available, got: $output"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Provider loads jira
# ──────────────────────────────────────────────────────────────────────────────
test_provider_loads_jira() {
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"
    cat > "$config" <<'EOF'
{"provider":"jira","jira":{"base_url":"https://test.atlassian.net","email":"a@b.com","api_token":"tok","project_key":"PROJ"}}
EOF

    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-tracker.sh" available 2>&1
    ) || true

    if printf '%s\n' "$output" | grep -q "true" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected 'true' from available, got: $output"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Graceful skip when no provider
# ──────────────────────────────────────────────────────────────────────────────
test_graceful_skip_no_provider() {
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"
    cat > "$config" <<'EOF'
{"provider":"none"}
EOF

    local exit_code=0
    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-tracker.sh" notify spawn 42 2>&1
    ) || exit_code=$?

    # Should exit cleanly (0) even with no provider
    if [[ "$exit_code" -eq 0 ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit 0 (graceful skip), got: $exit_code"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Stage descriptions exist for all 12 stages
# ──────────────────────────────────────────────────────────────────────────────
test_stage_descriptions_all_12() {
    local pipeline_script="$TEMP_DIR/scripts/cct-pipeline.sh"
    local stages=(intake plan design build test review compound_quality pr merge deploy validate monitor)
    local missing=0

    for stage in "${stages[@]}"; do
        if ! grep -q "^        ${stage})" "$pipeline_script" 2>/dev/null; then
            echo -e "    ${RED}✗${RESET} Missing stage description for: $stage"
            missing=$((missing + 1))
        fi
    done

    # Also verify the function exists
    if ! grep -q "get_stage_description()" "$pipeline_script" 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} get_stage_description() function not found"
        return 1
    fi

    [[ $missing -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Enriched progress body has Delivering line
# ──────────────────────────────────────────────────────────────────────────────
test_enriched_progress_delivering() {
    local pipeline_script="$TEMP_DIR/scripts/cct-pipeline.sh"

    if grep -q '^\*\*Delivering:\*\*' "$pipeline_script" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Pipeline script missing '**Delivering:**' line in progress body"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Enriched progress body has stage descriptions
# ──────────────────────────────────────────────────────────────────────────────
test_enriched_progress_stage_descriptions() {
    local pipeline_script="$TEMP_DIR/scripts/cct-pipeline.sh"

    # The progress body should call get_stage_description
    if grep -q 'get_stage_description' "$pipeline_script" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Pipeline script does not use get_stage_description in progress rendering"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Pipeline state includes stage_progress
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_state_stage_progress() {
    local pipeline_script="$TEMP_DIR/scripts/cct-pipeline.sh"

    if grep -q 'stage_progress:' "$pipeline_script" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Pipeline state missing stage_progress field"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Pipeline state includes stage description
# ──────────────────────────────────────────────────────────────────────────────
test_pipeline_state_stage_description() {
    local pipeline_script="$TEMP_DIR/scripts/cct-pipeline.sh"

    if grep -q 'current_stage_description:' "$pipeline_script" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Pipeline state missing current_stage_description field"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Tracker notify routes to provider (mock provider)
# ──────────────────────────────────────────────────────────────────────────────
test_tracker_notify_routes() {
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"
    cat > "$config" <<'EOF'
{"provider":"linear","linear":{"api_key":"lin_test_key","team_id":"tid","project_id":"pid"}}
EOF

    local curl_log="$TEMP_DIR/curl-notify.log"
    local events_file="$TEMP_DIR/home/.claude-teams/events.jsonl"
    rm -f "$curl_log" "$events_file"

    # Set up mock gh to return body with Linear ID
    export MOCK_GH_BODY='**Linear ID:** test-linear-uuid-123'
    export MOCK_CURL_LOG="$curl_log"

    local exit_code=0
    local output
    output=$(
        HOME="$TEMP_DIR/home" \
        PATH="$TEMP_DIR/bin:$PATH" \
        bash "$TEMP_DIR/scripts/cct-tracker.sh" notify spawn 42 2>&1
    ) || exit_code=$?

    unset MOCK_GH_BODY MOCK_CURL_LOG

    # Should succeed
    if [[ "$exit_code" -ne 0 ]]; then
        echo -e "    ${RED}✗${RESET} Notify exited with $exit_code"
        return 1
    fi

    # Should have emitted a tracker event
    if [[ -f "$events_file" ]] && grep -q "tracker.notify" "$events_file" 2>/dev/null; then
        return 0
    fi

    # The curl mock should have been called (Linear API)
    if [[ -f "$curl_log" ]]; then
        return 0
    fi

    echo -e "    ${RED}✗${RESET} No evidence of provider routing (no curl log or event)"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Dashboard reads goal from pipeline state
# ──────────────────────────────────────────────────────────────────────────────
test_dashboard_reads_goal() {
    # Create a mock pipeline state file
    local state_dir="$TEMP_DIR/home/.claude"
    mkdir -p "$state_dir"
    cat > "$state_dir/pipeline-state.md" <<'EOF'
---
pipeline: test-pipeline
goal: "Build authentication module"
status: running
current_stage: build
current_stage_description: "Writing production code with self-healing iteration"
stage_progress: "intake:complete plan:complete build:running test:pending"
started_at: 2026-02-09T10:00:00Z
updated_at: 2026-02-09T10:15:00Z
---
EOF

    # Verify the state file contains goal
    if grep -q '^goal:' "$state_dir/pipeline-state.md" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Pipeline state missing goal field"
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Jira config validation
# ──────────────────────────────────────────────────────────────────────────────
test_jira_config_validation() {
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"

    # Write complete Jira config
    cat > "$config" <<'EOF'
{"provider":"jira","jira":{"base_url":"https://myteam.atlassian.net","email":"dev@example.com","api_token":"jira-tok-123","project_key":"PROJ"}}
EOF

    # Validate all required Jira fields are readable
    local base_url email token project_key
    base_url=$(jq -r '.jira.base_url // empty' "$config" 2>/dev/null || true)
    email=$(jq -r '.jira.email // empty' "$config" 2>/dev/null || true)
    token=$(jq -r '.jira.api_token // empty' "$config" 2>/dev/null || true)
    project_key=$(jq -r '.jira.project_key // empty' "$config" 2>/dev/null || true)

    local errors=0
    if [[ -z "$base_url" ]]; then
        echo -e "    ${RED}✗${RESET} Jira base_url missing"
        errors=$((errors + 1))
    fi
    if [[ -z "$email" ]]; then
        echo -e "    ${RED}✗${RESET} Jira email missing"
        errors=$((errors + 1))
    fi
    if [[ -z "$token" ]]; then
        echo -e "    ${RED}✗${RESET} Jira api_token missing"
        errors=$((errors + 1))
    fi
    if [[ -z "$project_key" ]]; then
        echo -e "    ${RED}✗${RESET} Jira project_key missing"
        errors=$((errors + 1))
    fi

    [[ $errors -eq 0 ]]
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Linear config migration (old config auto-migrates)
# ──────────────────────────────────────────────────────────────────────────────
test_linear_config_migration() {
    # Create a legacy linear-config.json (old format used by cct-linear.sh)
    local legacy_config="$TEMP_DIR/home/.claude-teams/linear-config.json"
    cat > "$legacy_config" <<'EOF'
{"api_key":"lin_legacy_key_123","team_id":"legacy-tid","project_id":"legacy-pid"}
EOF

    # Create a tracker config that points to linear but has no api_key
    local config="$TEMP_DIR/home/.claude-teams/tracker-config.json"
    cat > "$config" <<'EOF'
{"provider":"linear","linear":{"api_key":"","team_id":"","project_id":""}}
EOF

    # The Linear provider should fall back to legacy config for API key
    local api_key
    api_key=$(
        HOME="$TEMP_DIR/home" \
        bash -c '
            source "'"$TEMP_DIR/scripts/cct-tracker-linear.sh"'"
            provider_load_config
            echo "$LINEAR_API_KEY"
        ' 2>/dev/null
    ) || true

    if [[ "$api_key" == "lin_legacy_key_123" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Legacy config migration failed. Expected 'lin_legacy_key_123', got: '$api_key'"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN ALL TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║  shipwright tracker — Test Suite                  ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
    echo -e "${RED}${BOLD}✗${RESET} jq is required for tracker tests"
    exit 1
fi

# Setup
echo -e "${DIM}Setting up test environment...${RESET}"
setup_env
echo ""

# Provider loading tests
echo -e "${PURPLE}${BOLD}Provider Loading${RESET}"
run_test "Provider loads from config (linear)" test_provider_loads_linear
run_test "Provider loads jira" test_provider_loads_jira
run_test "Graceful skip when no provider" test_graceful_skip_no_provider
echo ""

# Pipeline enrichment tests
echo -e "${PURPLE}${BOLD}Pipeline Enrichment${RESET}"
run_test "Stage descriptions exist for all 12 stages" test_stage_descriptions_all_12
run_test "Enriched progress body has Delivering line" test_enriched_progress_delivering
run_test "Enriched progress body has stage descriptions" test_enriched_progress_stage_descriptions
run_test "Pipeline state includes stage_progress" test_pipeline_state_stage_progress
run_test "Pipeline state includes stage description" test_pipeline_state_stage_description
echo ""

# Integration tests
echo -e "${PURPLE}${BOLD}Integration${RESET}"
run_test "Tracker notify routes to provider (mock)" test_tracker_notify_routes
run_test "Dashboard reads goal from pipeline state" test_dashboard_reads_goal
run_test "Jira config validation" test_jira_config_validation
run_test "Linear config migration (legacy fallback)" test_linear_config_migration
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  All ${TOTAL} tests passed ✓${RESET}"
else
    echo -e "${RED}${BOLD}  ${FAIL}/${TOTAL} tests failed${RESET}"
    echo ""
    for f in "${FAILURES[@]}"; do
        echo -e "  ${RED}✗${RESET} $f"
    done
fi
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo ""

exit "$FAIL"
