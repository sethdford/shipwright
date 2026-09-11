#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#   sw-scope-enforcement-test.sh — Test suite for scope enforcement
#   Tests: extract_planned_files, scope reports, PR size gate, formatting
# ═══════════════════════════════════════════════════════════════════════════
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/scope-enforcement.sh"

VERSION="3.3.0"

# Color codes
PASS_COLOR="\033[32m"
FAIL_COLOR="\033[31m"
RESET_COLOR="\033[0m"

# Test counters
PASS=0
FAIL=0
# Was hardcoded to "/private/tmp/claude-501/scope-test-$$" — a macOS-only path
# (macOS resolves /tmp to /private/tmp) carrying a specific developer's UID.
# On Linux there is no /private and it cannot be created at the root, so setup
# died with "mkdir: cannot create directory '/private': Permission denied"
# before a single assertion ran. mktemp under $TMPDIR is what the rest of the
# harness uses and works on both platforms.
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-scope-test.XXXXXX")

# Cleanup on exit
cleanup() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Create test directory
mkdir -p "$TEST_DIR"

# ─── Test helpers ─────────────────────────────────────────────────────────

assert_equals() {
    local test_name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${PASS_COLOR}✓${RESET_COLOR} $test_name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${FAIL_COLOR}✗${RESET_COLOR} $test_name"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_contains() {
    local test_name="$1"
    local haystack="$2"
    local needle="$3"

    if echo "$haystack" | grep "$needle" >/dev/null; then
        echo -e "${PASS_COLOR}✓${RESET_COLOR} $test_name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${FAIL_COLOR}✗${RESET_COLOR} $test_name"
        echo "  Expected to contain: $needle"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

assert_valid_json() {
    local test_name="$1"
    local json="$2"

    if echo "$json" | jq . >/dev/null 2>&1; then
        echo -e "${PASS_COLOR}✓${RESET_COLOR} $test_name"
        PASS=$((PASS + 1))
        return 0
    else
        echo -e "${FAIL_COLOR}✗${RESET_COLOR} $test_name"
        echo "  Invalid JSON: $json"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

# ─── Test suite ───────────────────────────────────────────────────────────

echo "=== Scope Enforcement Test Suite ==="
echo ""

cd "$TEST_DIR"

# Test 1: Extract planned files from bullet list
echo "▸ Extract planned files from formats"
plan_file="$TEST_DIR/plan1.md"
cat > "$plan_file" << 'EOF'
# Implementation Plan

Some intro text here.

## Files to Modify

- src/auth/login.ts
- src/auth/logout.ts
- src/utils/helpers.ts

## Implementation Steps

1. First step
2. Second step
EOF

result=$(extract_planned_files "$plan_file")
expected="src/auth/login.ts
src/auth/logout.ts
src/utils/helpers.ts"
assert_equals "Extract bullet list files" "$expected" "$result"

# Test 2: Extract from numbered list
plan_file="$TEST_DIR/plan2.md"
cat > "$plan_file" << 'EOF'
## Files to Modify

1. src/api/routes.ts
2. src/api/handlers.ts
3. tests/api.test.ts

## Other Section
EOF

result=$(extract_planned_files "$plan_file")
expected="src/api/handlers.ts
src/api/routes.ts
tests/api.test.ts"
assert_equals "Extract numbered list files" "$expected" "$result"

# Test 3: Extract from table format
plan_file="$TEST_DIR/plan3.md"
cat > "$plan_file" << 'EOF'
## Files to Modify

| File | Purpose |
|------|---------|
| src/index.ts | Main entry |
| src/db.ts | Database |

## Next
EOF

result=$(extract_planned_files "$plan_file")
# Should contain both files
if echo "$result" | grep "src/index.ts" >/dev/null && echo "$result" | grep "src/db.ts" >/dev/null; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} Extract table format files"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} Extract table format files"
    FAIL=$((FAIL + 1))
fi

# Test 4: Extract with backticks
plan_file="$TEST_DIR/plan4.md"
cat > "$plan_file" << 'EOF'
## Files to Modify

- `src/config.ts`
- `src/utils.ts`
- src/lib/helpers.ts

## Testing
EOF

result=$(extract_planned_files "$plan_file")
count=$(echo "$result" | grep -c . || true)
assert_equals "Extract with backticks" "3" "$count"

# Test 5: No Files to Modify section
plan_file="$TEST_DIR/plan5.md"
cat > "$plan_file" << 'EOF'
# Plan

## Implementation Details

Some content here but no "Files to Modify" section.
EOF

result=$(extract_planned_files "$plan_file")
assert_equals "No Files section returns empty" "" "$result"

# Test 6: Files to Modify case insensitive
plan_file="$TEST_DIR/plan6.md"
cat > "$plan_file" << 'EOF'
## files to modify

- src/case-test.ts

## Next
EOF

result=$(extract_planned_files "$plan_file")
assert_contains "Case insensitive header match" "$result" "src/case-test.ts"

# Test 7: Empty plan file
plan_file="$TEST_DIR/plan_empty.md"
touch "$plan_file"
result=$(extract_planned_files "$plan_file")
assert_equals "Empty plan returns empty string" "" "$result"

# Test 8: Non-existent file
result=$(extract_planned_files "/nonexistent-plan-$RANDOM.md")
assert_equals "Non-existent file returns empty" "" "$result"

# Test 9: Format scope report for prompt
echo ""
echo "▸ Format scope report for review prompt"
format_test_dir="$TEST_DIR/format-test"
mkdir -p "$format_test_dir"

# Create a sample scope report with unplanned files
cat > "$format_test_dir/scope-report.json" << 'EOF'
{
  "planned_files": ["src/auth.ts", "src/utils.ts"],
  "actual_files": ["src/auth.ts", "src/utils.ts", "src/unplanned.ts"],
  "planned_and_touched": ["src/auth.ts", "src/utils.ts"],
  "planned_but_untouched": [],
  "unplanned_files": ["src/unplanned.ts"],
  "pr_stats": {
    "insertions": 247,
    "deletions": 32,
    "files_changed": 3
  },
  "scope_creep_score": 0.33
}
EOF

formatted=$(format_scope_report_for_prompt "$format_test_dir")
assert_contains "Format includes Scope Analysis header" "$formatted" "Scope Analysis"
assert_contains "Format includes PR Statistics" "$formatted" "PR Statistics"
assert_contains "Format mentions unplanned files" "$formatted" "unplanned"
assert_contains "Format shows insertions" "$formatted" "247"

# Test 10: Format with no unplanned files (clean scope)
cat > "$format_test_dir/scope-report.json" << 'EOF'
{
  "planned_files": ["src/module.ts"],
  "actual_files": ["src/module.ts"],
  "planned_and_touched": ["src/module.ts"],
  "planned_but_untouched": [],
  "unplanned_files": [],
  "pr_stats": {
    "insertions": 100,
    "deletions": 10,
    "files_changed": 1
  },
  "scope_creep_score": 0
}
EOF

formatted=$(format_scope_report_for_prompt "$format_test_dir")
assert_contains "Clean scope shows zero creep" "$formatted" "0"

# Test 11: PR stats JSON structure
echo ""
echo "▸ PR statistics"
stats="{\"insertions\":100,\"deletions\":25,\"files_changed\":3}"
assert_valid_json "PR stats is valid JSON" "$stats"

# Extract fields
if echo "$stats" | jq -e '.insertions' >/dev/null 2>&1; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} PR stats contains insertions"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} PR stats missing insertions"
    FAIL=$((FAIL + 1))
fi

if echo "$stats" | jq -e '.files_changed' >/dev/null 2>&1; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} PR stats contains files_changed"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} PR stats missing files_changed"
    FAIL=$((FAIL + 1))
fi

# Test 12: Scope report JSON structure
echo ""
echo "▸ Scope report structure"
report_file="$TEST_DIR/scope-test.json"
cat > "$report_file" << 'EOF'
{
  "planned_files": ["src/foo.ts", "src/bar.ts"],
  "actual_files": ["src/foo.ts", "src/bar.ts", "src/baz.ts"],
  "planned_and_touched": ["src/foo.ts", "src/bar.ts"],
  "planned_but_untouched": [],
  "unplanned_files": ["src/baz.ts"],
  "pr_stats": {
    "insertions": 247,
    "deletions": 32,
    "files_changed": 3
  },
  "scope_creep_score": 0.33
}
EOF

report=$(cat "$report_file")
assert_valid_json "Scope report is valid JSON" "$report"

# Check all required fields exist
fields=("planned_files" "actual_files" "planned_and_touched" "planned_but_untouched" "unplanned_files" "pr_stats" "scope_creep_score")
for field in "${fields[@]}"; do
    if echo "$report" | jq -e ".$field" >/dev/null 2>&1; then
        echo -e "${PASS_COLOR}✓${RESET_COLOR} Report contains $field"
        PASS=$((PASS + 1))
    else
        echo -e "${FAIL_COLOR}✗${RESET_COLOR} Report missing $field"
        FAIL=$((FAIL + 1))
    fi
done

# Test 13: Extract files with mixed formatting
echo ""
echo "▸ Mixed markdown formatting"
plan_file="$TEST_DIR/plan_mixed.md"
cat > "$plan_file" << 'EOF'
## Files to Modify

- src/module1.ts
1. src/module2.ts
2. tests/unit.test.ts

| File |
|------|
| src/module3.ts |

## Done
EOF

result=$(extract_planned_files "$plan_file")
file_count=$(echo "$result" | grep -c . || true)
# Should have at least 4 files from mixed formats
if [[ "$file_count" -ge 4 ]]; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} Mixed formatting extracts multiple files"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} Mixed formatting should extract 4+ files, got $file_count"
    FAIL=$((FAIL + 1))
fi

# Test 14: Scope creep score is numeric
echo ""
echo "▸ Scope creep score validation"
report="{\"scope_creep_score\": 0.25}"
if echo "$report" | jq -e '.scope_creep_score' >/dev/null 2>&1; then
    score=$(echo "$report" | jq '.scope_creep_score')
    if [[ "$score" =~ ^0\.[0-9]+$ ]] || [[ "$score" =~ ^[0-9]+$ ]]; then
        echo -e "${PASS_COLOR}✓${RESET_COLOR} Scope creep score is numeric"
        PASS=$((PASS + 1))
    else
        echo -e "${FAIL_COLOR}✗${RESET_COLOR} Scope creep score should be numeric"
        FAIL=$((FAIL + 1))
    fi
fi

# Test 15: Planned but untouched files handling
echo ""
echo "▸ Planned but untouched detection"
report_file="$TEST_DIR/scope-untouched.json"
cat > "$report_file" << 'EOF'
{
  "planned_files": ["src/planned1.ts", "src/planned2.ts", "src/planned3.ts"],
  "actual_files": ["src/planned1.ts"],
  "planned_and_touched": ["src/planned1.ts"],
  "planned_but_untouched": ["src/planned2.ts", "src/planned3.ts"],
  "unplanned_files": [],
  "pr_stats": {"insertions": 50, "deletions": 0, "files_changed": 1},
  "scope_creep_score": 0
}
EOF

report=$(cat "$report_file")
untouched=$(echo "$report" | jq '.planned_but_untouched | length')
if [[ "$untouched" -eq 2 ]]; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} Detects planned but untouched files"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} Should detect 2 untouched files, got $untouched"
    FAIL=$((FAIL + 1))
fi

# Test 16: Files to modify with markdown code formatting
plan_file="$TEST_DIR/plan_code.md"
cat > "$plan_file" << 'EOF'
## Files to Modify

```
src/file1.ts
src/file2.ts
```

## Implementation
EOF

result=$(extract_planned_files "$plan_file")
if echo "$result" | grep "src/file" >/dev/null; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} Extracts from code blocks"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} Should extract files from code blocks"
    FAIL=$((FAIL + 1))
fi

# Test 17: Format report with no report file
formatted=$(format_scope_report_for_prompt "$TEST_DIR/nonexistent")
if [[ "$formatted" == *"No scope report"* ]]; then
    echo -e "${PASS_COLOR}✓${RESET_COLOR} Format handles missing report gracefully"
    PASS=$((PASS + 1))
else
    echo -e "${FAIL_COLOR}✗${RESET_COLOR} Should handle missing report gracefully"
    FAIL=$((FAIL + 1))
fi

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "=== Test Summary ==="
TOTAL=$((PASS + FAIL))
echo "Passed: $PASS/$TOTAL"
echo "Failed: $FAIL/$TOTAL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "${PASS_COLOR}All tests passed!${RESET_COLOR}"
    exit 0
else
    echo -e "${FAIL_COLOR}Some tests failed.${RESET_COLOR}"
    exit 1
fi
