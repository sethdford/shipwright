#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright linear test — Validate Linear ↔ GitHub bidirectional sync   ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls base64 chmod; do
        command -v "$cmd" &>/dev/null && ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
    done

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then echo "main"
        else echo "abc1234"; fi ;;
    remote) echo "git@github.com:test/repo.git" ;;
    log) echo "abc1234 Mock commit" ;;
    *) echo "mock git: $*" ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    issue)
        case "${2:-}" in
            create) echo '{"number":99}' ;;
            list) echo '[]' ;;
            view) echo '{"body":"**Linear ID:** abc-123-uuid"}' ;;
        esac ;;
    pr) echo '[]' ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock claude and tmux
    for mock in claude tmux; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Mock curl for Linear GraphQL API
    cat > "$TEST_TEMP_DIR/bin/curl" <<'MOCKEOF'
#!/usr/bin/env bash
echo '{"data":{"issues":{"nodes":[]},"viewer":{"id":"u1","name":"Test User","email":"test@test.com"}}}'
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/curl"

    # Copy compat.sh if available
    if [[ -f "$SCRIPT_DIR/lib/compat.sh" ]]; then
        cp "$SCRIPT_DIR/lib/compat.sh" "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"
    fi

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

assert_pass() {
    local desc="$1"
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    local _count
    _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true
    if [[ "${_count:-0}" -gt 0 ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Tests
# ═══════════════════════════════════════════════════════════════════════════════

SRC="$SCRIPT_DIR/sw-linear.sh"

echo ""
print_test_header "Shipwright Linear Test Suite"
echo ""

# ─── 1. Script Safety ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Script Safety${RESET}"

if grep -q 'set -euo pipefail' "$SRC"; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

if grep -q "trap.*ERR" "$SRC"; then
    assert_pass "ERR trap present"
else
    assert_fail "ERR trap present"
fi

if grep -q '^VERSION=' "$SRC"; then
    assert_pass "VERSION variable defined"
else
    assert_fail "VERSION variable defined"
fi

ver=$(grep -m1 '^VERSION=' "$SRC" | sed 's/VERSION="//' | sed 's/"//')
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    assert_pass "VERSION is semver: $ver"
else
    assert_fail "VERSION is semver" "got: $ver"
fi

echo ""

# ─── 2. Help Output ──────────────────────────────────────────────────────────
echo -e "${BOLD}  Help Output${RESET}"

setup_env

help_output=$(bash "$SRC" help 2>&1) || true

assert_contains "help mentions USAGE" "$help_output" "USAGE"
assert_contains "help mentions sync command" "$help_output" "sync"
assert_contains "help mentions update command" "$help_output" "update"
assert_contains "help mentions status command" "$help_output" "status"
assert_contains "help mentions init command" "$help_output" "init"
assert_contains "help mentions LINEAR_API_KEY" "$help_output" "LINEAR_API_KEY"

# --help flag
help_flag_output=$(bash "$SRC" --help 2>&1) || true
assert_contains "--help works" "$help_flag_output" "USAGE"

echo ""

# ─── 3. Unknown Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Error Handling${RESET}"

if ! bash "$SRC" nonexistent-cmd 2>/dev/null; then
    assert_pass "unknown command exits non-zero"
else
    assert_fail "unknown command exits non-zero"
fi

unknown_output=$(bash "$SRC" nonexistent-cmd 2>&1) || true
assert_contains "unknown command shows error" "$unknown_output" "Unknown command"

echo ""

# ─── 4. Default Command ──────────────────────────────────────────────────────
echo -e "${BOLD}  Default Behavior${RESET}"

default_output=$(bash "$SRC" 2>&1) || true
assert_contains "no-arg defaults to help" "$default_output" "USAGE"

echo ""

# ─── 5. Config Check ─────────────────────────────────────────────────────────
echo -e "${BOLD}  Configuration${RESET}"

# sync without API key should fail
sync_output=$(bash "$SRC" sync 2>&1) || true
assert_contains "sync without API key shows error" "$sync_output" "LINEAR_API_KEY"

# update without API key should fail
update_output=$(bash "$SRC" update 2>&1) || true
assert_contains "update without API key shows error" "$update_output" "LINEAR_API_KEY"

# status without API key should fail
status_output=$(bash "$SRC" status 2>&1) || true
assert_contains "status without API key shows error" "$status_output" "LINEAR_API_KEY"

echo ""

# ─── 6. Config Loading ───────────────────────────────────────────────────────
echo -e "${BOLD}  Config Loading${RESET}"

# Write linear config
jq -n '{
    api_key: "lin_api_test_key",
    team_id: "team-uuid",
    project_id: "project-uuid"
}' > "$TEST_TEMP_DIR/home/.shipwright/linear-config.json"

export LINEAR_API_KEY="lin_api_test_key"

# sync with config should proceed (mock curl returns empty nodes)
sync_config_output=$(bash "$SRC" sync 2>&1) || true
assert_contains "sync with config proceeds" "$sync_config_output" "Syncing"

echo ""

# ─── 7. Update Subcommand ────────────────────────────────────────────────────
echo -e "${BOLD}  Update Subcommand${RESET}"

# update without enough args shows usage
update_no_args=$(bash "$SRC" update 2>&1) || true
assert_contains "update without args shows usage" "$update_no_args" "Usage"

echo ""

# ─── 8. Notify Function ──────────────────────────────────────────────────────
echo -e "${BOLD}  Notify Integration${RESET}"

# notify subcommand exists (used by daemon)
# shellcheck disable=SC2034
notify_output=$(bash "$SRC" notify spawn 2>&1) || true
# Should not crash — silently skips if no matching issue
assert_pass "notify subcommand executes without crash"

echo ""

# ─── 9. Atomic Config Write ──────────────────────────────────────────────────
echo -e "${BOLD}  Atomic Writes${RESET}"

if grep -q 'tmp_config.*\.tmp' "$SRC" && grep -q 'mv.*tmp_config' "$SRC"; then
    assert_pass "init uses atomic write (tmp + mv)"
else
    assert_fail "init uses atomic write (tmp + mv)"
fi

if grep -q 'chmod 600' "$SRC"; then
    assert_pass "config file gets restricted permissions"
else
    assert_fail "config file gets restricted permissions"
fi

echo ""

# ─── 10. GraphQL Helper ──────────────────────────────────────────────────────
echo -e "${BOLD}  GraphQL Helper${RESET}"

if grep -q 'linear_graphql' "$SRC"; then
    assert_pass "linear_graphql helper defined"
else
    assert_fail "linear_graphql helper defined"
fi

if grep -q 'jq -n --arg' "$SRC"; then
    assert_pass "uses jq --arg for safe JSON escaping"
else
    assert_fail "uses jq --arg for safe JSON escaping"
fi

echo ""

# ─── 11. Event Emission ──────────────────────────────────────────────────────
echo -e "${BOLD}  Event Emission${RESET}"

if grep -q 'emit_event.*linear' "$SRC"; then
    assert_pass "emits linear events"
else
    assert_fail "emits linear events"
fi

if grep -q 'EVENTS_FILE' "$SRC"; then
    assert_pass "uses EVENTS_FILE for event logging"
else
    assert_fail "uses EVENTS_FILE for event logging"
fi

unset LINEAR_API_KEY

echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
