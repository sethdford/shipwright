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

assert_pass() { local desc="$1"; TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo -e "  ${GREEN}✓${RESET} ${desc}"; }
assert_fail() { local desc="$1"; local detail="${2:-}"; TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); FAILURES+=("$desc"); echo -e "  ${RED}✗${RESET} ${desc}"; if [[ -n "$detail" ]]; then echo -e "    ${DIM}${detail}${RESET}"; fi; }
assert_contains() { local desc="$1" haystack="$2" needle="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cF -- "$needle" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing: $needle"; fi; }
assert_contains_regex() { local desc="$1" haystack="$2" pattern="$3"; local _count; _count=$(printf '%s\n' "$haystack" | grep -cE -- "$pattern" 2>/dev/null) || true; if [[ "${_count:-0}" -gt 0 ]]; then assert_pass "$desc"; else assert_fail "$desc" "output missing pattern: $pattern"; fi; }

echo ""
print_test_header "Shipwright Decompose Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""
setup_env

# ─── Test 1: help flag ────────────────────────────────────────────────────
echo -e "  ${CYAN}help command${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" help 2>&1) && rc=0 || rc=$?
assert_eq "help exits 0" "0" "$rc"
assert_contains "help shows usage" "$output" "shipwright decompose"
assert_contains "help shows commands" "$output" "COMMANDS"

# ─── Test 2: --help flag ──────────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --help 2>&1) && rc=0 || rc=$?
assert_eq "--help exits 0" "0" "$rc"

# ─── Test 3: --version flag ───────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}version flag${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" --version 2>&1) && rc=0 || rc=$?
assert_eq "--version exits 0" "0" "$rc"
assert_contains "--version shows version" "$output" "3."

# ─── Test 4: unknown command ──────────────────────────────────────────────
echo ""
echo -e "  ${CYAN}error handling${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" bogus 2>&1) && rc=0 || rc=$?
assert_eq "unknown command exits 1" "1" "$rc"
assert_contains "unknown command shows error" "$output" "Unknown command"

# ─── Test 5: analyze missing args ─────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" analyze 2>&1) && rc=0 || rc=$?
assert_eq "analyze without issue exits 1" "1" "$rc"
assert_contains "analyze shows usage" "$output" "Usage"

# ─── Test 6: decompose missing args ───────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" decompose 2>&1) && rc=0 || rc=$?
assert_eq "decompose without issue exits 1" "1" "$rc"

# ─── Test 7: auto missing args ────────────────────────────────────────────
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" auto 2>&1) && rc=0 || rc=$?
assert_eq "auto without issue exits 1" "1" "$rc"

# ─── Test 8: analyze with NO_GITHUB ───────────────────────────────────────
echo ""
echo -e "  ${CYAN}analyze subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" analyze 42 2>&1) && rc=0 || rc=$?
assert_eq "analyze exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "analyze outputs complexity_score" "$output" "complexity_score"
assert_contains "analyze outputs should_decompose" "$output" "should_decompose"
assert_contains "analyze outputs subtasks" "$output" "subtasks"

# ─── Test 9: analyze JSON is valid ────────────────────────────────────────
# Extract JSON block from output (from first { to last })
json_output=$(printf '%s\n' "$output" | sed -n '/^{/,/^}/p')
if [[ -n "$json_output" ]] && printf '%s\n' "$json_output" | jq . >/dev/null 2>&1; then
    assert_pass "analyze outputs valid JSON"
else
    assert_fail "analyze outputs valid JSON"
fi

# ─── Test 10: analyze mock returns expected fields ─────────────────────────
complexity=$(printf '%s\n' "$json_output" | jq -r '.complexity_score' 2>/dev/null || echo "")
assert_eq "analyze returns complexity_score 85" "85" "$complexity"
should_decompose=$(printf '%s\n' "$json_output" | jq -r '.should_decompose' 2>/dev/null || echo "")
assert_eq "analyze returns should_decompose true" "true" "$should_decompose"

# ─── Test 11: decompose with NO_GITHUB (mock) ─────────────────────────────
echo ""
echo -e "  ${CYAN}decompose subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" decompose 42 2>&1) && rc=0 || rc=$?
assert_eq "decompose exits 0 with NO_GITHUB" "0" "$rc"
assert_contains "decompose shows decomposing" "$output" "Decomposing"

# ─── Test 12: auto with NO_GITHUB (mock) ──────────────────────────────────
echo ""
echo -e "  ${CYAN}auto subcommand (mock)${RESET}"
output=$(bash "$SCRIPT_DIR/sw-decompose.sh" auto 42 2>&1) && rc=0 || rc=$?
assert_eq "auto exits 0 with NO_GITHUB" "0" "$rc"

# ─── Test 13: events file created ─────────────────────────────────────────
echo ""
echo -e "  ${CYAN}state file creation${RESET}"
if [[ -f "$HOME/.shipwright/events.jsonl" ]]; then
    assert_pass "events.jsonl created"
else
    assert_fail "events.jsonl created"
fi

# ─── Test 14-28: DAG scheduling tests ─────────────────────────────────────
echo ""
echo -e "  ${CYAN}DAG scheduling (new features)${RESET}"

# Create test JSON with dependencies
analysis_file="$TEST_TEMP_DIR/analysis-with-deps.json"
cat > "$analysis_file" <<'JSON'
{
    "issue_number": 42,
    "complexity_score": 85,
    "estimated_hours": 12,
    "should_decompose": true,
    "reasoning": "Issue involves major architectural changes",
    "subtasks": [
        {
            "title": "Subtask 1: Design phase",
            "description": "Plan and document the new architecture",
            "depends_on": [],
            "estimated_hours": 3
        },
        {
            "title": "Subtask 2: Implementation phase",
            "description": "Implement core changes",
            "depends_on": [0],
            "estimated_hours": 6
        },
        {
            "title": "Subtask 3: Integration & testing",
            "description": "Integrate changes and add tests",
            "depends_on": [1],
            "estimated_hours": 3
        }
    ]
}
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
