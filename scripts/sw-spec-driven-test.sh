#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-spec-driven-test.sh — Specification-Driven Development Test Suite   ║
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
    local needle="$1" haystack="$2" description="${3:-}"
    if echo "$haystack" | grep -F "$needle" >/dev/null; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected to contain: $needle"
        echo "    Actual: $haystack"
    fi
}

assert_file_exists() {
    local path="$1" description="${2:-}"
    if [[ -f "$path" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    File not found: $path"
    fi
}

# ─── Setup ──────────────────────────────────────────────────────────────────
TMPDIR_TEST=$(mktemp -d 2>/dev/null || mktemp -d "${TMPDIR:-/tmp}/spec-driven-test-XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/spec-driven-test-$$")
mkdir -p "$TMPDIR_TEST" 2>/dev/null || true
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Override spec dir to temp
export SPEC_DIR="$TMPDIR_TEST/specs"

# Set up a minimal git repo for spec_diff
TEST_REPO="$TMPDIR_TEST/test-repo"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > file.txt
git add file.txt
git commit -q -m "initial commit"

# Source the module
source "$SCRIPT_DIR/lib/spec-driven.sh"

# ─── Test: spec_generate creates valid JSON file ───────────────────────────
test_generate_creates_file() {
    local output
    output=$(spec_generate "Add user auth" "- Login endpoint\n- JWT tokens" "" "" "typescript" 2>/dev/null)
    assert_file_exists "$output" "spec_generate creates a file"
}

# ─── Test: spec_generate has required fields ───────────────────────────────
test_generate_required_fields() {
    local spec_file
    spec_file=$(spec_generate "Test feature" "- Goal one\n- Goal two" "" "" "" 2>/dev/null)
    local version
    version=$(jq -r '.version' "$spec_file" 2>/dev/null || echo "FAIL")
    assert_equals "1.0" "$version" "generated spec has version 1.0"

    local title
    title=$(jq -r '.title' "$spec_file" 2>/dev/null || echo "FAIL")
    assert_equals "Test feature" "$title" "generated spec has correct title"

    local goals_count
    goals_count=$(jq '.goals | length' "$spec_file" 2>/dev/null || echo "0")
    assert_ge_local 1 "$goals_count" "generated spec has at least 1 goal"

    local criteria_count
    criteria_count=$(jq '.acceptance_criteria | length' "$spec_file" 2>/dev/null || echo "0")
    assert_ge_local 1 "$criteria_count" "generated spec has at least 1 acceptance criterion"
}

# local >= helper (avoid name collision with sourced modules)
assert_ge_local() {
    local threshold="$1" actual="$2" description="${3:-}"
    if [[ "$actual" -ge "$threshold" ]]; then
        PASS=$((PASS + 1))
        echo -e "  \033[38;2;74;222;128m\033[1m✓\033[0m $description"
    else
        FAIL=$((FAIL + 1))
        echo -e "  \033[38;2;248;113;113m\033[1m✗\033[0m $description"
        echo "    Expected >= $threshold, got: $actual"
    fi
}

# ─── Test: spec_generate with issue number sets source ─────────────────────
test_generate_with_issue() {
    local spec_file
    spec_file=$(spec_generate "Fix bug" "Fix the crash" "42" "" "" 2>/dev/null)
    local source_type
    source_type=$(jq -r '.source.type' "$spec_file" 2>/dev/null || echo "FAIL")
    assert_equals "github_issue" "$source_type" "spec with issue has github_issue source"
    local issue_num
    issue_num=$(jq -r '.source.issue_number' "$spec_file" 2>/dev/null || echo "0")
    assert_equals "42" "$issue_num" "spec has correct issue number"
}

# ─── Test: spec_generate estimates complexity from body length ─────────────
test_generate_complexity() {
    # Short body = simple
    local spec_file
    spec_file=$(spec_generate "Tiny fix" "fix" "" "" "" 2>/dev/null)
    local complexity
    complexity=$(jq -r '.metadata.complexity' "$spec_file" 2>/dev/null || echo "FAIL")
    assert_equals "simple" "$complexity" "short body yields simple complexity"

    # Long body = complex
    local long_body
    long_body=$(printf 'x%.0s' $(seq 1 500))
    spec_file=$(spec_generate "Big feature" "$long_body" "" "" "" 2>/dev/null)
    complexity=$(jq -r '.metadata.complexity' "$spec_file" 2>/dev/null || echo "FAIL")
    assert_equals "complex" "$complexity" "500-char body yields complex complexity"
}

# ─── Test: spec_validate passes on valid spec ──────────────────────────────
test_validate_valid() {
    local spec_file
    spec_file=$(spec_generate "Valid spec" "- A goal" "" "" "" 2>/dev/null)
    local result=0
    spec_validate "$spec_file" >/dev/null 2>&1 || result=$?
    assert_equals "0" "$result" "validate passes on valid spec"
}

# ─── Test: spec_validate fails on missing title ───────────────────────────
test_validate_missing_title() {
    local bad_spec="$TMPDIR_TEST/bad-spec.json"
    echo '{"version":"1.0","goals":["x"],"acceptance_criteria":[{"criterion":"y","testable":true}]}' > "$bad_spec"
    # jq '.title' on this returns null, which is treated as empty
    # Actually title field is missing entirely
    local result=0
    spec_validate "$bad_spec" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "validate fails when title is missing"
}

# ─── Test: spec_validate fails on empty goals ─────────────────────────────
test_validate_empty_goals() {
    local bad_spec="$TMPDIR_TEST/no-goals.json"
    echo '{"version":"1.0","title":"test","goals":[],"acceptance_criteria":[{"criterion":"y","testable":true}]}' > "$bad_spec"
    local result=0
    spec_validate "$bad_spec" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "validate fails when goals is empty"
}

# ─── Test: spec_validate fails on nonexistent file ─────────────────────────
test_validate_no_file() {
    local result=0
    spec_validate "/nonexistent/spec.json" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "validate fails on nonexistent file"
}

# ─── Test: spec_to_prompt formats markdown output ──────────────────────────
test_to_prompt_format() {
    local spec_file
    spec_file=$(spec_generate "Prompt test" "- Build widget" "" "" "" 2>/dev/null)
    local output
    output=$(spec_to_prompt "$spec_file" 2>/dev/null)
    assert_contains "## Specification:" "$output" "to_prompt includes specification header"
    assert_contains "### Goals" "$output" "to_prompt includes Goals section"
    assert_contains "### Acceptance Criteria" "$output" "to_prompt includes Acceptance Criteria section"
}

# ─── Test: spec_to_prompt returns 1 on missing file ───────────────────────
test_to_prompt_missing_file() {
    local result=0
    spec_to_prompt "/nonexistent/file.json" >/dev/null 2>&1 || result=$?
    assert_equals "1" "$result" "to_prompt returns 1 on missing file"
}

# ─── Test: module guard ───────────────────────────────────────────────────
test_module_guard() {
    assert_equals "1" "$_SPEC_DRIVEN_LOADED" "module guard variable is set"
}

# ─── Main ───────────────────────────────────────────────────────────────────
echo "sw-spec-driven-test.sh"
test_generate_creates_file
test_generate_required_fields
test_generate_with_issue
test_generate_complexity
test_validate_valid
test_validate_missing_title
test_validate_empty_goals
test_validate_no_file
test_to_prompt_format
test_to_prompt_missing_file
test_module_guard

echo ""
echo "PASS: $PASS"
echo "FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
