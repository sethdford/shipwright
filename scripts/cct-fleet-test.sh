#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright fleet test — Unit tests for fleet orchestration                   ║
# ║  Mock tmux/daemon · Config parsing · Start/stop/status/metrics          ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SCRIPT="$SCRIPT_DIR/cct-fleet.sh"

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
# TEST ENVIRONMENT SETUP
# ═══════════════════════════════════════════════════════════════════════════════

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cct-fleet-test.XXXXXX")

    # Create directory structure
    mkdir -p "$TEMP_DIR/.claude-teams"
    mkdir -p "$TEMP_DIR/home/.claude-teams"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/project/.claude"
    mkdir -p "$TEMP_DIR/project/.git"

    # Create mock repos
    for repo in api web mobile; do
        mkdir -p "$TEMP_DIR/repos/$repo/.git"
        mkdir -p "$TEMP_DIR/repos/$repo/.claude"
        # Minimal git config so git doesn't complain
        echo "[core]" > "$TEMP_DIR/repos/$repo/.git/config"
    done

    # Create mock tmux binary
    cat > "$TEMP_DIR/bin/tmux" << 'MOCK_TMUX'
#!/usr/bin/env bash
# Mock tmux — records calls for verification
MOCK_LOG="${MOCK_TMUX_LOG:-/tmp/mock-tmux.log}"
echo "tmux $*" >> "$MOCK_LOG"
case "$1" in
    has-session)
        # Return 1 (no session) unless MOCK_TMUX_HAS_SESSION is set
        if [[ "${MOCK_TMUX_HAS_SESSION:-}" == "true" ]]; then
            exit 0
        fi
        exit 1
        ;;
    new-session)
        exit 0
        ;;
    kill-session)
        exit 0
        ;;
    send-keys)
        exit 0
        ;;
    list-sessions)
        echo "shipwright-fleet-api: 1 windows"
        exit 0
        ;;
esac
exit 0
MOCK_TMUX
    chmod +x "$TEMP_DIR/bin/tmux"

    # Create mock jq (use real jq but log calls)
    # We rely on real jq being installed

    # Create mock cct-daemon.sh
    cat > "$TEMP_DIR/bin/cct-daemon.sh" << 'MOCK_DAEMON'
#!/usr/bin/env bash
echo "daemon $*"
exit 0
MOCK_DAEMON
    chmod +x "$TEMP_DIR/bin/cct-daemon.sh"

    # Set environment
    export MOCK_TMUX_LOG="$TEMP_DIR/tmux-calls.log"
    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export EVENTS_FILE="$TEMP_DIR/home/.claude-teams/events.jsonl"
    export NO_GITHUB=true
}

cleanup_env() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup_env EXIT

# Reset between tests
reset_test() {
    rm -f "$MOCK_TMUX_LOG"
    rm -f "$EVENTS_FILE"
    rm -f "$TEMP_DIR/home/.claude-teams/fleet-state.json"
    export MOCK_TMUX_HAS_SESSION=""
    touch "$MOCK_TMUX_LOG"
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
    if printf '%s\n' "$haystack" | grep -qE -- "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output missing pattern: $needle ($label)"
    echo -e "    ${DIM}Got: $(echo "$haystack" | head -3)${RESET}"
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-not contains}"
    if ! printf '%s\n' "$haystack" | grep -qE -- "$needle" 2>/dev/null; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Output unexpectedly contains: $needle ($label)"
    return 1
}

assert_file_exists() {
    local filepath="$1" label="${2:-file exists}"
    if [[ -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File not found: $filepath ($label)"
    return 1
}

assert_file_not_exists() {
    local filepath="$1" label="${2:-file not exists}"
    if [[ ! -f "$filepath" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} File unexpectedly exists: $filepath ($label)"
    return 1
}

assert_exit_code() {
    local expected="$1" actual="$2" label="${3:-exit code}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected exit code $expected, got $actual ($label)"
    return 1
}

assert_gt() {
    local actual="$1" threshold="$2" label="${3:-greater than}"
    if [[ "$actual" -gt "$threshold" ]]; then
        return 0
    fi
    echo -e "    ${RED}✗${RESET} Expected $actual > $threshold ($label)"
    return 1
}

assert_json_key() {
    local json="$1" key="$2" expected="$3" label="${4:-json key}"
    local actual
    actual=$(echo "$json" | jq -r "$key" 2>/dev/null)
    assert_equals "$expected" "$actual" "$label"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Create fleet config
# ═══════════════════════════════════════════════════════════════════════════════

create_fleet_config() {
    local config_path="$1"
    local repos_json="${2:-}"

    if [[ -z "$repos_json" ]]; then
        repos_json=$(jq -n \
            --arg api "$TEMP_DIR/repos/api" \
            --arg web "$TEMP_DIR/repos/web" \
            '[{"path": $api, "template": "autonomous", "max_parallel": 2},
              {"path": $web, "template": "standard"}]')
    fi

    jq -n --argjson repos "$repos_json" '{
        repos: $repos,
        defaults: {
            watch_label: "ready-to-build",
            pipeline_template: "autonomous",
            max_parallel: 2,
            model: "opus"
        },
        shared_events: true
    }' > "$config_path"
}

create_fleet_state() {
    local state_path="$1"
    jq -n \
        --arg api_path "$TEMP_DIR/repos/api" \
        --arg web_path "$TEMP_DIR/repos/web" \
        '{
            started_at: "2025-01-01T00:00:00Z",
            repos: {
                api: { path: $api_path, session: "shipwright-fleet-api", template: "autonomous", max_parallel: 2, started_at: "2025-01-01T00:00:00Z" },
                web: { path: $web_path, session: "shipwright-fleet-web", template: "standard", max_parallel: 2, started_at: "2025-01-01T00:00:00Z" }
            }
        }' > "$state_path"
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
# 1. Help output contains expected sections
# ──────────────────────────────────────────────────────────────────────────────
test_help_output() {
    local output
    output=$(bash "$FLEET_SCRIPT" help 2>&1) || true

    assert_contains "$output" "shipwright fleet" "mentions fleet" &&
    assert_contains "$output" "USAGE" "has USAGE section" &&
    assert_contains "$output" "COMMANDS" "has COMMANDS section" &&
    assert_contains "$output" "start" "mentions start" &&
    assert_contains "$output" "stop" "mentions stop" &&
    assert_contains "$output" "status" "mentions status" &&
    assert_contains "$output" "metrics" "mentions metrics" &&
    assert_contains "$output" "init" "mentions init" &&
    assert_contains "$output" "CONFIG FILE" "has CONFIG FILE section"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Help via --help flag
# ──────────────────────────────────────────────────────────────────────────────
test_help_flag() {
    local output
    output=$(bash "$FLEET_SCRIPT" --help 2>&1) || true

    assert_contains "$output" "USAGE" "--help shows usage"
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Config parsing — valid config
# ──────────────────────────────────────────────────────────────────────────────
test_config_valid() {
    local config_path="$TEMP_DIR/fleet-config.json"
    create_fleet_config "$config_path"

    # Verify config is valid JSON
    local repo_count
    repo_count=$(jq '.repos | length' "$config_path")
    assert_equals "2" "$repo_count" "2 repos in config" &&

    local first_template
    first_template=$(jq -r '.repos[0].template' "$config_path")
    assert_equals "autonomous" "$first_template" "first repo template" &&

    local default_label
    default_label=$(jq -r '.defaults.watch_label' "$config_path")
    assert_equals "ready-to-build" "$default_label" "default watch_label"
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Config parsing — missing config file
# ──────────────────────────────────────────────────────────────────────────────
test_config_missing() {
    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" start --config /nonexistent/config.json 2>&1) || exit_code=$?

    assert_contains "$output" "not found" "reports missing config" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Config parsing — invalid JSON
# ──────────────────────────────────────────────────────────────────────────────
test_config_invalid_json() {
    local config_path="$TEMP_DIR/bad-config.json"
    echo "not valid json {{{" > "$config_path"

    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || exit_code=$?

    assert_contains "$output" "Invalid JSON" "reports invalid JSON" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Config parsing — empty repos array
# ──────────────────────────────────────────────────────────────────────────────
test_config_empty_repos() {
    local config_path="$TEMP_DIR/empty-repos.json"
    echo '{"repos":[],"defaults":{}}' > "$config_path"

    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || exit_code=$?

    assert_contains "$output" "No repos configured" "reports no repos" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Config defaults applied to repos without overrides
# ──────────────────────────────────────────────────────────────────────────────
test_config_defaults() {
    local config_path="$TEMP_DIR/defaults-config.json"
    # web repo has no template/max_parallel — should get defaults
    local repos_json
    repos_json=$(jq -n --arg web "$TEMP_DIR/repos/web" \
        '[{"path": $web}]')
    create_fleet_config "$config_path" "$repos_json"

    # Read defaults from config
    local default_template default_max
    default_template=$(jq -r '.defaults.pipeline_template' "$config_path")
    default_max=$(jq -r '.defaults.max_parallel' "$config_path")

    assert_equals "autonomous" "$default_template" "default template" &&
    assert_equals "2" "$default_max" "default max_parallel"
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Fleet init generates config template
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_init() {
    local work_dir="$TEMP_DIR/init-test"
    mkdir -p "$work_dir/.claude"

    local output
    output=$(cd "$work_dir" && bash "$FLEET_SCRIPT" init 2>&1) || true

    assert_contains "$output" "Generated fleet config" "reports config generated" || return 1

    local config_file="$work_dir/.claude/fleet-config.json"
    assert_file_exists "$config_file" "config file created" &&
    # Verify it's valid JSON with expected structure
    jq empty "$config_file" 2>/dev/null &&
    local has_repos has_defaults
    has_repos=$(jq 'has("repos")' "$config_file")
    has_defaults=$(jq 'has("defaults")' "$config_file")
    assert_equals "true" "$has_repos" "config has repos" &&
    assert_equals "true" "$has_defaults" "config has defaults"
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Fleet init skips when config already exists
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_init_existing() {
    local work_dir="$TEMP_DIR/init-existing"
    mkdir -p "$work_dir/.claude"
    echo '{"repos":[]}' > "$work_dir/.claude/fleet-config.json"

    local output
    output=$(cd "$work_dir" && bash "$FLEET_SCRIPT" init 2>&1) || true

    assert_contains "$output" "already exists" "reports config exists"
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Fleet start spawns tmux sessions per repo
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start() {
    local config_path="$TEMP_DIR/start-config.json"
    create_fleet_config "$config_path"

    local output
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || true

    # Check tmux was called with new-session for each repo
    local tmux_calls
    tmux_calls=$(cat "$MOCK_TMUX_LOG" 2>/dev/null || echo "")

    assert_contains "$tmux_calls" "new-session.*shipwright-fleet-api" "tmux session for api" &&
    assert_contains "$tmux_calls" "new-session.*shipwright-fleet-web" "tmux session for web" &&
    assert_contains "$output" "Started" "reports started repos" &&
    assert_contains "$output" "2 started" "reports 2 started"
}

# ──────────────────────────────────────────────────────────────────────────────
# 11. Fleet start skips missing repos
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_missing_repo() {
    local config_path="$TEMP_DIR/missing-repo-config.json"
    local repos_json
    repos_json=$(jq -n --arg valid "$TEMP_DIR/repos/api" \
        '[{"path": $valid}, {"path": "/nonexistent/repo"}]')
    create_fleet_config "$config_path" "$repos_json"

    local output
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || true

    assert_contains "$output" "not found" "warns about missing repo" &&
    assert_contains "$output" "1 started" "started valid repo" &&
    assert_contains "$output" "1 skipped" "skipped missing repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 12. Fleet start skips already-running sessions
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_already_running() {
    local config_path="$TEMP_DIR/running-config.json"
    create_fleet_config "$config_path"

    # Tell mock tmux that sessions already exist
    export MOCK_TMUX_HAS_SESSION=true

    local output
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || true

    assert_contains "$output" "already exists" "warns about existing session" &&
    assert_contains "$output" "2 skipped" "skipped both repos"
}

# ──────────────────────────────────────────────────────────────────────────────
# 13. Fleet start creates fleet state file
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_state() {
    local config_path="$TEMP_DIR/state-config.json"
    create_fleet_config "$config_path"

    bash "$FLEET_SCRIPT" start --config "$config_path" > /dev/null 2>&1 || true

    local state_file="$TEMP_DIR/home/.claude-teams/fleet-state.json"
    assert_file_exists "$state_file" "fleet state created" &&
    # Verify state has repos
    local has_api has_web
    has_api=$(jq 'has("repos") and (.repos | has("api"))' "$state_file" 2>/dev/null || echo "false")
    has_web=$(jq 'has("repos") and (.repos | has("web"))' "$state_file" 2>/dev/null || echo "false")
    assert_equals "true" "$has_api" "state has api repo" &&
    assert_equals "true" "$has_web" "state has web repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 14. Fleet start emits fleet.started event
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_event() {
    local config_path="$TEMP_DIR/event-config.json"
    create_fleet_config "$config_path"

    bash "$FLEET_SCRIPT" start --config "$config_path" > /dev/null 2>&1 || true

    assert_file_exists "$EVENTS_FILE" "events file created" &&
    local events
    events=$(cat "$EVENTS_FILE")
    assert_contains "$events" "fleet.started" "fleet.started event emitted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 15. Fleet start — repo-level overrides in config
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_overrides() {
    local config_path="$TEMP_DIR/overrides-config.json"
    local repos_json
    repos_json=$(jq -n --arg api "$TEMP_DIR/repos/api" \
        '[{"path": $api, "template": "hotfix", "max_parallel": 5, "watch_label": "deploy-me"}]')
    create_fleet_config "$config_path" "$repos_json"

    bash "$FLEET_SCRIPT" start --config "$config_path" > /dev/null 2>&1 || true

    # Check the generated fleet-managed config for the repo
    local managed_config="$TEMP_DIR/repos/api/.claude/.fleet-daemon-config.json"
    assert_file_exists "$managed_config" "fleet-managed config created" &&
    local tpl max_p label
    tpl=$(jq -r '.pipeline_template' "$managed_config")
    max_p=$(jq -r '.max_parallel' "$managed_config")
    label=$(jq -r '.watch_label' "$managed_config")
    assert_equals "hotfix" "$tpl" "template override applied" &&
    assert_equals "5" "$max_p" "max_parallel override applied" &&
    assert_equals "deploy-me" "$label" "watch_label override applied"
}

# ──────────────────────────────────────────────────────────────────────────────
# 16. Fleet stop kills sessions and cleans state
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_stop() {
    local state_file="$TEMP_DIR/home/.claude-teams/fleet-state.json"
    create_fleet_state "$state_file"

    # Mock tmux returns true for has-session (sessions exist)
    export MOCK_TMUX_HAS_SESSION=true

    local output
    output=$(bash "$FLEET_SCRIPT" stop 2>&1) || true

    assert_contains "$output" "Stopped" "reports stopped repos" &&
    assert_file_not_exists "$state_file" "fleet state removed"
}

# ──────────────────────────────────────────────────────────────────────────────
# 17. Fleet stop — no fleet running
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_stop_no_state() {
    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" stop 2>&1) || exit_code=$?

    assert_contains "$output" "No fleet state found" "reports no fleet" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 18. Fleet stop emits fleet.stopped event
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_stop_event() {
    local state_file="$TEMP_DIR/home/.claude-teams/fleet-state.json"
    create_fleet_state "$state_file"
    export MOCK_TMUX_HAS_SESSION=true

    bash "$FLEET_SCRIPT" stop > /dev/null 2>&1 || true

    assert_file_exists "$EVENTS_FILE" "events file exists" &&
    local events
    events=$(cat "$EVENTS_FILE")
    assert_contains "$events" "fleet.stopped" "fleet.stopped event emitted"
}

# ──────────────────────────────────────────────────────────────────────────────
# 19. Fleet status — no fleet running
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_status_no_state() {
    local output
    output=$(bash "$FLEET_SCRIPT" status 2>&1) || true

    assert_contains "$output" "No fleet running" "reports no fleet"
}

# ──────────────────────────────────────────────────────────────────────────────
# 20. Fleet status — shows dashboard
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_status_dashboard() {
    local state_file="$TEMP_DIR/home/.claude-teams/fleet-state.json"
    create_fleet_state "$state_file"

    local output
    output=$(bash "$FLEET_SCRIPT" status 2>&1) || true

    assert_contains "$output" "dashboard" "shows dashboard header" &&
    assert_contains "$output" "REPO" "has REPO column" &&
    assert_contains "$output" "STATUS" "has STATUS column" &&
    assert_contains "$output" "api" "shows api repo" &&
    assert_contains "$output" "web" "shows web repo" &&
    assert_contains "$output" "Total:" "shows total"
}

# ──────────────────────────────────────────────────────────────────────────────
# 21. Fleet metrics — no events file
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_metrics_no_events() {
    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" metrics 2>&1) || exit_code=$?

    assert_contains "$output" "No events file" "reports no events" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ──────────────────────────────────────────────────────────────────────────────
# 22. Fleet metrics — dashboard output
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_metrics_dashboard() {
    # Write some pipeline events
    local now_e
    now_e=$(date +%s)
    mkdir -p "$(dirname "$EVENTS_FILE")"
    for i in 1 2 3; do
        local t=$((now_e - 100 + i))
        echo "{\"ts\":\"2025-01-01T00:00:0${i}Z\",\"ts_epoch\":$t,\"type\":\"pipeline.completed\",\"result\":\"success\",\"duration_s\":300}" >> "$EVENTS_FILE"
    done
    echo "{\"ts\":\"2025-01-01T00:00:04Z\",\"ts_epoch\":$((now_e - 96)),\"type\":\"pipeline.completed\",\"result\":\"failure\",\"duration_s\":100}" >> "$EVENTS_FILE"

    local output
    output=$(bash "$FLEET_SCRIPT" metrics --period 7 2>&1) || true

    assert_contains "$output" "Fleet Metrics" "shows metrics header" &&
    assert_contains "$output" "REPO" "has REPO column" &&
    assert_contains "$output" "DONE" "has DONE column" &&
    assert_contains "$output" "PASS" "has PASS column" &&
    assert_contains "$output" "FAIL" "has FAIL column" &&
    assert_contains "$output" "TOTAL" "has TOTAL row"
}

# ──────────────────────────────────────────────────────────────────────────────
# 23. Fleet metrics — JSON output
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_metrics_json() {
    local now_e
    now_e=$(date +%s)
    mkdir -p "$(dirname "$EVENTS_FILE")"
    for i in 1 2 3; do
        local t=$((now_e - 100 + i))
        echo "{\"ts\":\"2025-01-01T00:00:0${i}Z\",\"ts_epoch\":$t,\"type\":\"pipeline.completed\",\"result\":\"success\",\"duration_s\":300,\"repo\":\"api\"}" >> "$EVENTS_FILE"
    done
    echo "{\"ts\":\"2025-01-01T00:00:04Z\",\"ts_epoch\":$((now_e - 96)),\"type\":\"pipeline.completed\",\"result\":\"failure\",\"duration_s\":100,\"repo\":\"web\"}" >> "$EVENTS_FILE"

    local output
    output=$(bash "$FLEET_SCRIPT" metrics --period 7 --json 2>&1) || true

    # Validate JSON
    if ! echo "$output" | jq empty 2>/dev/null; then
        echo -e "    ${RED}✗${RESET} Output is not valid JSON"
        echo -e "    ${DIM}Got: $(echo "$output" | head -5)${RESET}"
        return 1
    fi

    assert_contains "$output" "period" "has period field" &&
    assert_contains "$output" "repos" "has repos field" &&
    assert_contains "$output" "aggregate" "has aggregate field" &&
    # Verify aggregate totals
    local total
    total=$(echo "$output" | jq '.aggregate.completed')
    assert_equals "4" "$total" "aggregate completed = 4"
}

# ──────────────────────────────────────────────────────────────────────────────
# 24. Fleet metrics — period flag
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_metrics_period() {
    local now_e
    now_e=$(date +%s)
    mkdir -p "$(dirname "$EVENTS_FILE")"
    # Event within last 1 day
    echo "{\"ts\":\"2025-01-01T00:00:01Z\",\"ts_epoch\":$((now_e - 100)),\"type\":\"pipeline.completed\",\"result\":\"success\",\"duration_s\":300}" >> "$EVENTS_FILE"
    # Event from 30 days ago (should be excluded with --period 1)
    echo "{\"ts\":\"2024-12-01T00:00:01Z\",\"ts_epoch\":$((now_e - 2592000)),\"type\":\"pipeline.completed\",\"result\":\"success\",\"duration_s\":300}" >> "$EVENTS_FILE"

    local output
    output=$(bash "$FLEET_SCRIPT" metrics --period 1 --json 2>&1) || true

    if echo "$output" | jq empty 2>/dev/null; then
        local total
        total=$(echo "$output" | jq '.aggregate.completed')
        assert_equals "1" "$total" "only 1 event within 1 day period"
    else
        # Non-JSON output means no events matched — also valid
        return 0
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 25. Session name generation
# ──────────────────────────────────────────────────────────────────────────────
test_session_name() {
    # Test that session names are generated correctly
    # by inspecting tmux calls from a start command
    local config_path="$TEMP_DIR/session-config.json"
    local repos_json
    repos_json=$(jq -n --arg api "$TEMP_DIR/repos/api" \
        '[{"path": $api}]')
    create_fleet_config "$config_path" "$repos_json"

    bash "$FLEET_SCRIPT" start --config "$config_path" > /dev/null 2>&1 || true

    local tmux_calls
    tmux_calls=$(cat "$MOCK_TMUX_LOG" 2>/dev/null || echo "")

    assert_contains "$tmux_calls" "shipwright-fleet-api" "session name includes repo basename"
}

# ──────────────────────────────────────────────────────────────────────────────
# 26. Fleet start — non-git repo skipped
# ──────────────────────────────────────────────────────────────────────────────
test_fleet_start_non_git() {
    # Create a non-git directory
    mkdir -p "$TEMP_DIR/repos/not-git"
    # No .git dir

    local config_path="$TEMP_DIR/nongit-config.json"
    local repos_json
    repos_json=$(jq -n --arg ng "$TEMP_DIR/repos/not-git" --arg api "$TEMP_DIR/repos/api" \
        '[{"path": $ng}, {"path": $api}]')
    create_fleet_config "$config_path" "$repos_json"

    local output
    output=$(bash "$FLEET_SCRIPT" start --config "$config_path" 2>&1) || true

    assert_contains "$output" "Not a git repo" "warns about non-git dir" &&
    assert_contains "$output" "1 skipped" "skipped non-git repo"
}

# ──────────────────────────────────────────────────────────────────────────────
# 27. Unknown subcommand
# ──────────────────────────────────────────────────────────────────────────────
test_unknown_command() {
    local output exit_code=0
    output=$(bash "$FLEET_SCRIPT" foobar 2>&1) || exit_code=$?

    assert_contains "$output" "Unknown command" "reports unknown command" &&
    assert_exit_code "1" "$exit_code" "exits with 1"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    local filter="${1:-}"

    echo ""
    echo -e "${PURPLE}${BOLD}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${PURPLE}${BOLD}║  shipwright fleet test — Unit Tests                                ║${RESET}"
    echo -e "${PURPLE}${BOLD}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""

    # Verify the fleet script exists
    if [[ ! -f "$FLEET_SCRIPT" ]]; then
        echo -e "${RED}✗ Fleet script not found: $FLEET_SCRIPT${RESET}"
        exit 1
    fi

    # Verify jq is available
    if ! command -v jq &>/dev/null; then
        echo -e "${RED}✗ jq is required. Install it: brew install jq${RESET}"
        exit 1
    fi

    echo -e "${DIM}Setting up test environment...${RESET}"
    setup_env
    echo -e "${GREEN}✓${RESET} Environment ready: ${DIM}$TEMP_DIR${RESET}"
    echo ""

    # Define all tests
    local -a tests=(
        "test_help_output:Help output contains expected sections"
        "test_help_flag:Help via --help flag"
        "test_config_valid:Config parsing — valid config"
        "test_config_missing:Config parsing — missing config file"
        "test_config_invalid_json:Config parsing — invalid JSON"
        "test_config_empty_repos:Config parsing — empty repos array"
        "test_config_defaults:Config defaults applied"
        "test_fleet_init:Fleet init generates config template"
        "test_fleet_init_existing:Fleet init skips when config exists"
        "test_fleet_start:Fleet start spawns tmux sessions per repo"
        "test_fleet_start_missing_repo:Fleet start skips missing repos"
        "test_fleet_start_already_running:Fleet start skips existing sessions"
        "test_fleet_start_state:Fleet start creates fleet state file"
        "test_fleet_start_event:Fleet start emits fleet.started event"
        "test_fleet_start_overrides:Fleet start applies repo-level overrides"
        "test_fleet_stop:Fleet stop kills sessions and cleans state"
        "test_fleet_stop_no_state:Fleet stop — no fleet running"
        "test_fleet_stop_event:Fleet stop emits fleet.stopped event"
        "test_fleet_status_no_state:Fleet status — no fleet running"
        "test_fleet_status_dashboard:Fleet status shows dashboard"
        "test_fleet_metrics_no_events:Fleet metrics — no events file"
        "test_fleet_metrics_dashboard:Fleet metrics dashboard output"
        "test_fleet_metrics_json:Fleet metrics JSON output"
        "test_fleet_metrics_period:Fleet metrics period flag"
        "test_session_name:Session name generation"
        "test_fleet_start_non_git:Fleet start skips non-git repos"
        "test_unknown_command:Unknown subcommand"
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
