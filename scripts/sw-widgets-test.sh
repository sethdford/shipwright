#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright widgets test — Validate embeddable status widgets            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"
    mkdir -p "$TEST_TEMP_DIR/repo/.claude"
    mkdir -p "$TEST_TEMP_DIR/repo/scripts/lib"

    # Link real utilities
    for cmd in jq date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf tr cut head tail tee touch find ls; do
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

    # Mock gh, claude, tmux, curl
    for mock in gh claude tmux curl; do
        printf '#!/usr/bin/env bash\necho "mock %s: $*"\nexit 0\n' "$mock" > "$TEST_TEMP_DIR/bin/$mock"
        chmod +x "$TEST_TEMP_DIR/bin/$mock"
    done

    # Create minimal compat.sh
    touch "$TEST_TEMP_DIR/repo/scripts/lib/compat.sh"

    # Create a package.json for version detection
    echo '{"version": "2.0.0"}' > "$TEST_TEMP_DIR/repo/package.json"

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT




# ─── Tests ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}shipwright widgets${RESET} ${DIM}— test suite${RESET}"
echo ""

# ─── Script structure ─────────────────────────────────────────────────────────
echo -e "${BOLD}Script structure${RESET}"

# 1. VERSION defined
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-widgets.sh" || true)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined at top of sw-widgets.sh"
else
    assert_fail "VERSION variable defined at top of sw-widgets.sh"
fi

# 2. set -euo pipefail
safety_line=$(grep '^set -euo pipefail' "$SCRIPT_DIR/sw-widgets.sh" || true)
if [[ -n "$safety_line" ]]; then
    assert_pass "set -euo pipefail present"
else
    assert_fail "set -euo pipefail present"
fi

# 3. ERR trap
err_trap=$(grep "trap.*ERR" "$SCRIPT_DIR/sw-widgets.sh" || true)
if [[ -n "$err_trap" ]]; then
    assert_pass "ERR trap defined"
else
    assert_fail "ERR trap defined"
fi

# 4. Source guard pattern
guard=$(grep 'BASH_SOURCE\[0\].*==.*\$0' "$SCRIPT_DIR/sw-widgets.sh" || true)
if [[ -n "$guard" ]]; then
    assert_pass "Source guard pattern (BASH_SOURCE check) present"
else
    assert_fail "Source guard pattern (BASH_SOURCE check) present"
fi

# 5. Color definitions
color_count=$(grep -c 'CYAN\|GREEN\|RED\|YELLOW\|PURPLE' "$SCRIPT_DIR/sw-widgets.sh" 2>/dev/null) || true
if [[ "${color_count:-0}" -ge 5 ]]; then
    assert_pass "Standard color definitions present"
else
    assert_fail "Standard color definitions present" "found $color_count"
fi

# 6. Output helpers
for helper in "info()" "success()" "warn()" "error()"; do
    helper_found=$(grep -c "$helper" "$SCRIPT_DIR/sw-widgets.sh" 2>/dev/null) || true
    if [[ "${helper_found:-0}" -gt 0 ]]; then
        assert_pass "Output helper $helper defined"
    else
        assert_fail "Output helper $helper defined"
    fi
done

echo ""
echo -e "${BOLD}Help command${RESET}"

setup_env

# 7. help exits 0
if bash "$SCRIPT_DIR/sw-widgets.sh" help &>/dev/null; then
    assert_pass "help exits 0"
else
    assert_fail "help exits 0"
fi

# 8. --help exits 0
if bash "$SCRIPT_DIR/sw-widgets.sh" --help &>/dev/null; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0"
fi

# 9. help contains USAGE
help_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" help 2>&1) || true
assert_contains "help contains USAGE" "$help_output" "USAGE"

# 10. help lists badge command
assert_contains "help lists badge command" "$help_output" "badge"

# 11. help lists slack command
assert_contains "help lists slack command" "$help_output" "slack"

# 12. help lists markdown command
assert_contains "help lists markdown command" "$help_output" "markdown"

# 13. help lists json command
assert_contains "help lists json command" "$help_output" "json"

# 14. help lists notify command
assert_contains "help lists notify command" "$help_output" "notify"

echo ""
echo -e "${BOLD}Version command${RESET}"

# 15. version command outputs version
setup_env
version_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" version 2>&1) || true
assert_contains "version command outputs version string" "$version_output" "widgets v"

echo ""
echo -e "${BOLD}Unknown command${RESET}"

# 16. Unknown command exits non-zero
setup_env
if bash "$SCRIPT_DIR/sw-widgets.sh" nonexistent_command &>/dev/null 2>&1; then
    assert_fail "Unknown command exits non-zero"
else
    assert_pass "Unknown command exits non-zero"
fi

# 17. Unknown command shows error message
unknown_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" nonexistent_command 2>&1) || true
assert_contains "Unknown command shows error" "$unknown_output" "Unknown command"

echo ""
echo -e "${BOLD}Badge command${RESET}"

# 18. badge pipeline generates shields.io URL
setup_env
badge_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge pipeline 2>&1) || true
assert_contains "badge pipeline returns shields.io URL" "$badge_output" "img.shields.io"

# 19. badge tests generates shields.io URL
badge_tests_out=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge tests 2>&1) || true
assert_contains "badge tests returns shields.io URL" "$badge_tests_out" "img.shields.io"

# 20. badge version generates shields.io URL
badge_ver_out=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge version 2>&1) || true
assert_contains "badge version returns shields.io URL" "$badge_ver_out" "img.shields.io"

# 21. badge health generates shields.io URL
badge_health_out=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge health 2>&1) || true
assert_contains "badge health returns shields.io URL" "$badge_health_out" "img.shields.io"

# 22. badge all shows all badge types
badge_all_out=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge all 2>&1) || true
assert_contains "badge all shows Pipeline" "$badge_all_out" "Pipeline:"
assert_contains "badge all shows Tests" "$badge_all_out" "Tests:"
assert_contains "badge all shows Version" "$badge_all_out" "Version:"
assert_contains "badge all shows Health" "$badge_all_out" "Health:"

# 23. badge unknown type exits non-zero
if bash "$SCRIPT_DIR/sw-widgets.sh" badge bogus_type &>/dev/null 2>&1; then
    assert_fail "badge unknown type exits non-zero"
else
    assert_pass "badge unknown type exits non-zero"
fi

echo ""
echo -e "${BOLD}Markdown command${RESET}"

# 24. markdown generates status block
setup_env
md_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" markdown 2>&1) || true
assert_contains "markdown contains Status Badges header" "$md_output" "Status Badges"
assert_contains "markdown contains Pipeline Status section" "$md_output" "Pipeline Status"
assert_contains "markdown contains shields.io URLs" "$md_output" "img.shields.io"
assert_contains "markdown contains Shipwright attribution" "$md_output" "Shipwright"

echo ""
echo -e "${BOLD}JSON command${RESET}"

# 25. json command outputs valid JSON
setup_env
json_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" json 2>&1) || true
if echo "$json_output" | jq . &>/dev/null; then
    assert_pass "json command outputs valid JSON"
else
    assert_fail "json command outputs valid JSON" "invalid JSON output"
fi

# 26. json has expected fields
timestamp_val=$(echo "$json_output" | jq -r '.timestamp // empty' 2>/dev/null || true)
if [[ -n "$timestamp_val" ]]; then
    assert_pass "json contains timestamp field"
else
    assert_fail "json contains timestamp field"
fi

pipeline_status=$(echo "$json_output" | jq -r '.pipeline.status // empty' 2>/dev/null || true)
if [[ -n "$pipeline_status" ]]; then
    assert_pass "json contains pipeline.status"
else
    assert_fail "json contains pipeline.status"
fi

badges_pipeline=$(echo "$json_output" | jq -r '.badges.pipeline // empty' 2>/dev/null || true)
if [[ -n "$badges_pipeline" ]]; then
    assert_pass "json contains badges.pipeline"
else
    assert_fail "json contains badges.pipeline"
fi

echo ""
echo -e "${BOLD}Notify command${RESET}"

# 27. notify always shows status
setup_env
notify_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" notify always 2>&1) || true
assert_contains "notify always shows pipeline status" "$notify_output" "Pipeline status"

# 28. notify success with unknown status (no output)
notify_success=$(bash "$SCRIPT_DIR/sw-widgets.sh" notify success 2>&1) || true
# When status is "unknown", notify success should NOT print "passing"
pass_count=$(printf '%s\n' "$notify_success" | grep -cF "passing" 2>/dev/null) || true
if [[ "${pass_count:-0}" -eq 0 ]]; then
    assert_pass "notify success with unknown pipeline status produces no output"
else
    assert_fail "notify success with unknown pipeline status produces no output"
fi

# 29. notify unknown type exits non-zero
if bash "$SCRIPT_DIR/sw-widgets.sh" notify bogus_type &>/dev/null 2>&1; then
    assert_fail "notify unknown type exits non-zero"
else
    assert_pass "notify unknown type exits non-zero"
fi

echo ""
echo -e "${BOLD}Pipeline status detection${RESET}"

# 30. Script reads pipeline-state.md for status
if grep -q 'pipeline-state.md' "$SCRIPT_DIR/sw-widgets.sh"; then
    assert_pass "Script reads pipeline-state.md for status"
else
    assert_fail "Script reads pipeline-state.md for status"
fi

# 31. Script handles passing/failing/running states
if grep -q 'passing\|failing\|running\|unknown' "$SCRIPT_DIR/sw-widgets.sh"; then
    assert_pass "Script handles pipeline status states"
else
    assert_fail "Script handles pipeline status states"
fi

# 32. Badge pipeline outputs something (even with no state file)
setup_env
badge_out=$(bash "$SCRIPT_DIR/sw-widgets.sh" badge pipeline 2>&1) || true
if [[ -n "$badge_out" ]]; then
    assert_pass "badge pipeline produces output"
else
    assert_fail "badge pipeline produces output" "no output"
fi

echo ""
echo -e "${BOLD}Slack command validation${RESET}"

# 33. slack without webhook exits non-zero
setup_env
if bash "$SCRIPT_DIR/sw-widgets.sh" slack &>/dev/null 2>&1; then
    assert_fail "slack without webhook URL exits non-zero"
else
    assert_pass "slack without webhook URL exits non-zero"
fi

# 34. slack error message mentions webhook
slack_err=$(bash "$SCRIPT_DIR/sw-widgets.sh" slack 2>&1) || true
assert_contains "slack error mentions webhook" "$slack_err" "webhook"

echo ""
echo -e "${BOLD}No-args defaults to help${RESET}"

# 35. No-args defaults to help
setup_env
noargs_output=$(bash "$SCRIPT_DIR/sw-widgets.sh" 2>&1) || true
assert_contains "No args defaults to help (shows USAGE)" "$noargs_output" "USAGE"

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
echo ""
print_test_results
