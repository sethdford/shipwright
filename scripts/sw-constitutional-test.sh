#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-constitutional-test.sh — Constitutional AI Test Suite                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

# ─── Test helpers ───────────────────────────────────────────────────────────
assert_equals() {
    local expected="$1" actual="$2" description="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected: $expected"
        echo "    Actual:   $actual"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="${3:-}"
    if echo "$haystack" | grep -F "$needle" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    In: $(echo "$haystack" | head -3)"
    fi
}

assert_json_field() {
    local json="$1" field="$2" expected="$3" description="${4:-}"
    local actual
    actual=$(echo "$json" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected $field = $expected"
        echo "    Actual:   $actual"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/sw-constitutional-test.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/sw-constitutional-test.$$")
mkdir -p "$TEST_DIR" 2>/dev/null || true

cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Create test constitution (use printf to avoid heredoc quoting issues)
printf '%s\n' '{
  "version": "1.0",
  "principles": {
    "security": [
      {"id": "SEC-001", "rule": "No hardcoded passwords", "severity": "critical", "check": "grep -nE '"'"'password\\s*='"'"' {file}"},
      {"id": "SEC-002", "rule": "Validate inputs", "severity": "critical"}
    ],
    "quality": [
      {"id": "QUA-001", "rule": "No TODO comments", "severity": "low", "check": "grep -n TODO {file}"},
      {"id": "QUA-002", "rule": "No magic numbers", "severity": "medium"}
    ],
    "error_handling": [
      {"id": "ERR-001", "rule": "No generic error messages", "severity": "medium", "check": "grep -ni '"'"'error occurred'"'"' {file}"}
    ]
  }
}' > "$TEST_DIR/test-constitution.json"

# Source the library
source "$SCRIPT_DIR/lib/constitutional.sh"

# ─── Test 1: Load constitution from explicit path ───────────────────────────
test_load_explicit() {
    _CONSTITUTIONAL_JSON=""
    _CONSTITUTIONAL_SOURCE=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    local version
    version=$(echo "$_CONSTITUTIONAL_JSON" | jq -r '.version' 2>/dev/null)
    assert_equals "1.0" "$version" "Load constitution from explicit path"
}

# ─── Test 2: Load fails gracefully with missing file ────────────────────────
test_load_missing() {
    _CONSTITUTIONAL_JSON=""
    _CONSTITUTIONAL_SOURCE=""
    # Override fallback paths so the function can't find any constitution
    local old_default="$CONSTITUTIONAL_DEFAULT_PATH"
    local old_override="$CONSTITUTIONAL_PROJECT_OVERRIDE"
    local old_script_dir="${SCRIPT_DIR:-}"
    CONSTITUTIONAL_DEFAULT_PATH="/nonexistent/default.json"
    CONSTITUTIONAL_PROJECT_OVERRIDE="/nonexistent/override.json"
    SCRIPT_DIR="/nonexistent"
    local exit_code=0
    constitutional_load "/nonexistent/path.json" 2>/dev/null || exit_code=$?
    CONSTITUTIONAL_DEFAULT_PATH="$old_default"
    CONSTITUTIONAL_PROJECT_OVERRIDE="$old_override"
    SCRIPT_DIR="$old_script_dir"
    assert_equals "1" "$exit_code" "Load fails with missing file"
}

# ─── Test 3: Get all principles ─────────────────────────────────────────────
test_get_all_principles() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    local principles
    principles=$(constitutional_get_principles)
    local count
    count=$(echo "$principles" | jq 'length' 2>/dev/null || echo "0")
    assert_equals "5" "$count" "Get all principles returns 5 items"
}

# ─── Test 4: Get principles by category ─────────────────────────────────────
test_get_by_category() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    local principles
    principles=$(constitutional_get_principles "security")
    local count
    count=$(echo "$principles" | jq 'length' 2>/dev/null || echo "0")
    assert_equals "2" "$count" "Get security principles returns 2 items"
}

# ─── Test 5: Get principles by severity ──────────────────────────────────────
test_get_by_severity() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    local principles
    principles=$(constitutional_get_principles "" "critical")
    local count
    count=$(echo "$principles" | jq 'length' 2>/dev/null || echo "0")
    assert_equals "2" "$count" "Filter by critical severity returns 2 items"
}

# ─── Test 6: Check file detects violations ───────────────────────────────────
test_check_file_violations() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"

    # Create a file with violations
    cat > "$TEST_DIR/bad-code.sh" <<'EOF'
#!/bin/bash
password = "hunter2"
# TODO: fix this later
echo "error occurred"
EOF

    local violations
    violations=$(constitutional_check_file "$TEST_DIR/bad-code.sh")
    local count
    count=$(echo "$violations" | jq 'length' 2>/dev/null || echo "0")
    # Should find: password match (SEC-001), TODO (QUA-001), error occurred (ERR-001)
    if [[ "$count" -ge 3 ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Check file detects $count violations (>= 3 expected)"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Check file detects violations"
        echo "    Expected >= 3 violations, got $count"
    fi
}

# ─── Test 7: Check file with no violations ───────────────────────────────────
test_check_clean_file() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"

    cat > "$TEST_DIR/clean-code.sh" <<'EOF'
#!/bin/bash
echo "hello world"
exit 0
EOF

    local violations
    violations=$(constitutional_check_file "$TEST_DIR/clean-code.sh")
    local count
    count=$(echo "$violations" | jq 'length' 2>/dev/null || echo "0")
    assert_equals "0" "$count" "Clean file has no violations"
}

# ─── Test 8: Check nonexistent file returns empty ────────────────────────────
test_check_nonexistent() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    local violations
    violations=$(constitutional_check_file "/nonexistent/file.sh")
    assert_equals "[]" "$violations" "Nonexistent file returns empty array"
}

# ─── Test 9: Violation JSON structure ────────────────────────────────────────
test_violation_structure() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"

    cat > "$TEST_DIR/has-todo.sh" <<'EOF'
# TODO: this needs fixing
EOF

    local violations
    violations=$(constitutional_check_file "$TEST_DIR/has-todo.sh")
    assert_json_field "$violations" '.[0].principle_id' "QUA-001" "Violation has principle_id"
    assert_json_field "$violations" '.[0].severity' "low" "Violation has severity"
    assert_json_field "$violations" '.[0].type' "automated" "Violation type is automated"
}

# ─── Test 10: Self-critique generates report ─────────────────────────────────
test_self_critique_report() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"

    local report_file="$TEST_DIR/report.json"
    CONSTITUTIONAL_REPORT_FILE="$report_file"

    # Self-critique with a non-existent base (will find no diff, so 0 violations)
    local total
    total=$(constitutional_self_critique "HEAD" "$report_file" 2>/dev/null) || true
    total="${total:-0}"

    if [[ -f "$report_file" ]]; then
        local verdict
        verdict=$(jq -r '.summary.verdict' "$report_file" 2>/dev/null || echo "")
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Self-critique generates report file"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Self-critique generates report file"
    fi
}

# ─── Test 11: Inject prompt produces formatted output ────────────────────────
test_inject_prompt() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    CONSTITUTIONAL_REPORT_FILE="$TEST_DIR/no-report.json"

    local output
    output=$(constitutional_inject_prompt)
    assert_contains "$output" "Code Constitution" "Inject prompt contains header"
    assert_contains "$output" "SEC-001" "Inject prompt contains principle IDs"
}

# ─── Test 12: Inject prompt with severity filter ─────────────────────────────
test_inject_prompt_severity_filter() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"
    CONSTITUTIONAL_REPORT_FILE="$TEST_DIR/no-report.json"

    local output
    output=$(constitutional_inject_prompt "" "critical")
    assert_contains "$output" "SEC-001" "Critical filter includes SEC-001"
    # QUA-001 is low severity, should NOT appear
    if echo "$output" | grep -F "QUA-001" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Critical filter excludes QUA-001 (low severity)"
    else
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m Critical filter excludes QUA-001 (low severity)"
    fi
}

# ─── Test 13: Format violations produces readable output ─────────────────────
test_format_violations() {
    local violations='[{"principle_id":"SEC-001","severity":"critical","rule":"No passwords","file":"test.sh","line":5,"match":"password=secret","type":"automated"}]'
    local output
    output=$(constitutional_format_violations "$violations")
    assert_contains "$output" "VIOLATION [critical] SEC-001" "Format violations includes severity and ID"
    assert_contains "$output" "test.sh:5" "Format violations includes file:line"
}

# ─── Test 14: Report JSON structure ──────────────────────────────────────────
test_report_structure() {
    _CONSTITUTIONAL_JSON=""
    constitutional_load "$TEST_DIR/test-constitution.json"

    local report_file="$TEST_DIR/report-struct.json"
    CONSTITUTIONAL_REPORT_FILE="$report_file"

    constitutional_self_critique "HEAD" "$report_file" >/dev/null 2>&1 || true

    if [[ -f "$report_file" ]]; then
        assert_json_field "$(cat "$report_file")" '.summary | has("total_violations")' "true" "Report has total_violations"
        assert_json_field "$(cat "$report_file")" '.summary | has("verdict")' "true" "Report has verdict"
        assert_json_field "$(cat "$report_file")" 'has("violations")' "true" "Report has violations array"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m Report file not created for structure check"
    fi
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-constitutional-test.sh"
test_load_explicit
test_load_missing
test_get_all_principles
test_get_by_category
test_get_by_severity
test_check_file_violations
test_check_clean_file
test_check_nonexistent
test_violation_structure
test_self_critique_report
test_inject_prompt
test_inject_prompt_severity_filter
test_format_violations
test_report_structure

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
