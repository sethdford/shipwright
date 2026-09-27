#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright decompose test — Intelligent Issue Decomposition tests       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/bin"
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/git"
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCK'
#!/usr/bin/env bash
echo '{"issue_number": 42, "complexity_score": 85, "should_decompose": true, "subtasks": []}'
exit 0
MOCK
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

JSON

# Test schedule command
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" schedule "$analysis_file" 42 2>&1) && rc=0 || rc=$?
assert_eq "schedule exits 0" "0" "$rc"
assert_contains "schedule shows valid DAG" "$output" "acyclic"
assert_contains "schedule shows waves" "$output" "Wave"

# Test critical-path command
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" critical-path "$analysis_file" 2>&1) && rc=0 || rc=$?
assert_eq "critical-path exits 0" "0" "$rc"
assert_contains "critical-path shows title" "$output" "Critical Path"
assert_contains "critical-path shows hours" "$output" "critical_path_hours"

# Test visualize text format
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" visualize "$analysis_file" text 2>&1) && rc=0 || rc=$?
assert_eq "visualize text exits 0" "0" "$rc"
assert_contains "visualize shows DAG title" "$output" "Dependencies DAG"
assert_contains "visualize shows task 0" "$output" "[0]"

# Test visualize mermaid format
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" visualize "$analysis_file" mermaid 2>&1) && rc=0 || rc=$?
assert_eq "visualize mermaid exits 0" "0" "$rc"
assert_contains "visualize mermaid has graph" "$output" "graph TD"

# Test help shows new commands
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" help 2>&1) && rc=0 || rc=$?
assert_contains "help shows schedule cmd" "$output" "schedule"
assert_contains "help shows critical-path cmd" "$output" "critical-path"
assert_contains "help shows visualize cmd" "$output" "visualize"

# Test version shows current version
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --version 2>&1) && rc=0 || rc=$?
expected_ver=$(jq -r '.version' "$SCRIPT_DIR/../package.json" 2>/dev/null || echo "3")
assert_contains "version shows $expected_ver" "$output" "$expected_ver"

# Test analyze mock data includes dependencies
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" analyze 99 2>&1) && rc=0 || rc=$?
json_output=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
if [[ -n "$json_output" ]] && printf '%s\n' "$json_output" | jq '.subtasks[0].depends_on' >/dev/null 2>&1; then
    assert_pass "mock data includes depends_on field"
else
    assert_fail "mock data includes depends_on field"
fi

echo ""
echo ""
print_test_results
