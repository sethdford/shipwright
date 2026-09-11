#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright quality-profile test — Unit tests for quality profile library ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Quality Profile Tests"

setup_test_env "sw-quality-profile-test"
trap cleanup_test_env EXIT

# Setup test repo structure in a writable location
# (Don't mock git — use real git so we can initialize a proper repo)
TEST_REPO="$TEST_TEMP_DIR/project"
mkdir -p "$TEST_REPO/.claude"
cd "$TEST_REPO"

# Create a mock git repo so git commands work
git init > /dev/null 2>&1 || true

# Override environment for quality-profile.sh
export REPO_ROOT="$TEST_REPO"
QUALITY_PROFILE_PATH="$TEST_REPO/.claude/quality-profile.json"

# Source the library (clear any existing cache)
_QUALITY_PROFILE_LOADED=""
source "$SCRIPT_DIR/lib/quality-profile.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Profile loading with defaults
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Profile loading with defaults"

profile=$(load_quality_profile)
assert_contains "profile has version" "$profile" '"version": 1'
assert_contains "profile has architecture section" "$profile" '"architecture":'
assert_contains "profile has testing section" "$profile" '"testing":'
assert_contains "profile has quality section" "$profile" '"quality":'
assert_contains "profile has review section" "$profile" '"review":'
assert_contains "profile has scope section" "$profile" '"scope":'
assert_contains "profile has deployment section" "$profile" '"deployment":'

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Schema validation
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Schema validation"

# Valid profile
valid_profile='{
  "version": 1,
  "project_name": "test",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {},
  "testing": {},
  "quality": {},
  "review": {},
  "scope": {},
  "deployment": {}
}'

if validate_quality_profile "$valid_profile"; then
    assert_pass "Valid profile passes validation"
else
    assert_fail "Valid profile passes validation" "validation returned false"
fi

# Invalid JSON
if validate_quality_profile "{ invalid json }"; then
    assert_fail "Invalid JSON rejected" "did not reject"
else
    assert_pass "Invalid JSON rejected"
fi

# Missing required field (no architecture)
invalid_missing='{
  "version": 1,
  "project_name": "test",
  "testing": {},
  "quality": {},
  "review": {},
  "scope": {},
  "deployment": {}
}'

if validate_quality_profile "$invalid_missing"; then
    assert_fail "Missing required field rejected" "did not reject"
else
    assert_pass "Missing required field rejected"
fi

# Wrong version
invalid_version='{
  "version": 999,
  "project_name": "test",
  "architecture": {},
  "testing": {},
  "quality": {},
  "review": {},
  "scope": {},
  "deployment": {}
}'

if validate_quality_profile "$invalid_version"; then
    assert_fail "Invalid version rejected" "did not reject"
else
    assert_pass "Invalid version rejected"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_get with and without defaults
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "qp_get function"

# Create a test profile with known values
test_profile='{
  "version": 1,
  "project_name": "myproject",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {"pattern": "microservices"},
  "testing": {"philosophy": "tdd"},
  "quality": {"max_pr_lines": 750},
  "review": {"min_issues_to_find": 5},
  "scope": {"decomposition_threshold_lines": 1000},
  "deployment": {"strategy": "staged_rollout"}
}'

echo "$test_profile" > "$QUALITY_PROFILE_PATH"
qp_clear_cache

# Get existing value
result=$(qp_get ".architecture.pattern")
assert_eq "qp_get returns existing value" "microservices" "$result"

# Get with fallback (key exists)
result=$(qp_get ".quality.max_pr_lines" "500")
assert_eq "qp_get returns value, ignores default" "750" "$result"

# Get non-existent with fallback
result=$(qp_get ".nonexistent.key" "fallback_value")
assert_eq "qp_get returns fallback for missing key" "fallback_value" "$result"

# Get non-existent without fallback (empty)
result=$(qp_get ".nonexistent.key2")
assert_eq "qp_get returns empty for missing key without default" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_get_array
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "qp_get_array function"

array_profile='{
  "version": 1,
  "project_name": "test",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {
    "layers": ["api", "service", "storage"],
    "rules": ["no cycles", "inbound only"]
  },
  "testing": {},
  "quality": {
    "never_ship": ["console.log", "debugger;", "TODO"],
    "always_require": ["unit tests", "docstrings"]
  },
  "review": {},
  "scope": {},
  "deployment": {}
}'

echo "$array_profile" > "$QUALITY_PROFILE_PATH"
qp_clear_cache

# Get array values
result=$(qp_get_array ".architecture.layers")
line_count=$(echo "$result" | wc -l | tr -d ' ')
assert_eq "qp_get_array returns 3 items" "3" "$line_count"
assert_contains "array contains 'api'" "$result" "api"
assert_contains "array contains 'service'" "$result" "service"
assert_contains "array contains 'storage'" "$result" "storage"

# Get quality never_ship array
result=$(qp_get_array ".quality.never_ship")
assert_contains "never_ship contains console.log" "$result" "console.log"
assert_contains "never_ship contains debugger" "$result" "debugger;"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_add_learned_rule and qp_get_rules_for_stage
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Learned rules addition and retrieval"

# Create a fresh profile
fresh_profile='{
  "version": 1,
  "project_name": "test",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {},
  "testing": {},
  "quality": {"learned_rules": []},
  "review": {},
  "scope": {},
  "deployment": {}
}'

echo "$fresh_profile" > "$QUALITY_PROFILE_PATH"
qp_clear_cache

# Add a learned rule
if qp_add_learned_rule "Always validate user input" "3 PRs had injection issues" "0.92" "plan,build"; then
    assert_pass "qp_add_learned_rule succeeds"
else
    assert_fail "qp_add_learned_rule succeeds" "function returned false"
fi

# Verify file was written
if [[ -f "$QUALITY_PROFILE_PATH" ]]; then
    assert_pass "Quality profile file exists after add rule"
else
    assert_fail "Quality profile file exists after add rule"
fi

# Get rules for 'plan' stage
rules=$(qp_get_rules_for_stage "plan")
assert_contains "Rules for plan stage include added rule" "$rules" "Always validate user input"

# Get rules for 'build' stage
rules=$(qp_get_rules_for_stage "build")
assert_contains "Rules for build stage include added rule" "$rules" "Always validate user input"

# Get rules for non-existent stage (should return empty)
rules=$(qp_get_rules_for_stage "nonexistent" || echo "")
assert_eq "Rules for nonexistent stage returns empty" "" "$rules"

# Add another rule with different stages
qp_add_learned_rule "Add comprehensive error handling" "Incident from unhandled promise" "0.88" "review"

# Verify both rules exist
rules_for_plan=$(qp_get_rules_for_stage "plan")
rules_for_review=$(qp_get_rules_for_stage "review")

assert_contains "Plan stage has first rule" "$rules_for_plan" "Always validate user input"
assert_contains "Review stage has second rule" "$rules_for_review" "Add comprehensive error handling"

# First rule should NOT be in review stage
if ! echo "$rules_for_review" | grep "Always validate user input" >/dev/null; then
    assert_pass "Review stage does not contain first rule"
else
    assert_fail "Review stage does not contain first rule"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: generate_default_profile
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Default profile generation"

rm -f "$QUALITY_PROFILE_PATH"
qp_clear_cache

default=$(generate_default_profile)

if validate_quality_profile "$default"; then
    assert_pass "Generated default profile is valid"
else
    assert_fail "Generated default profile is valid"
fi

assert_contains "Default has correct version" "$default" '"version": 1'
assert_contains "Default has architecture" "$default" '"architecture":'
assert_contains "Default has testing" "$default" '"testing":'
assert_contains "Default includes project_name" "$default" '"project_name":'
assert_contains "Default has generated_at timestamp" "$default" '"generated_at":'

# Check defaults are reasonable
max_lines=$(echo "$default" | jq -r '.quality.max_pr_lines')
assert_eq "Default max_pr_lines is 500" "500" "$max_lines"

max_files=$(echo "$default" | jq -r '.quality.max_files_per_pr')
assert_eq "Default max_files_per_pr is 15" "15" "$max_files"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_save
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "qp_save function"

rm -f "$QUALITY_PROFILE_PATH"
qp_clear_cache

save_profile='{
  "version": 1,
  "project_name": "savetest",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {"pattern": "library"},
  "testing": {"philosophy": "tdd"},
  "quality": {"max_pr_lines": 600},
  "review": {"min_issues_to_find": 4},
  "scope": {},
  "deployment": {}
}'

if qp_save "$save_profile"; then
    assert_pass "qp_save succeeds with valid profile"
else
    assert_fail "qp_save succeeds with valid profile"
fi

if [[ -f "$QUALITY_PROFILE_PATH" ]]; then
    assert_pass "Profile file created by qp_save"
else
    assert_fail "Profile file created by qp_save"
fi

# Verify it's readable JSON
saved_content=$(cat "$QUALITY_PROFILE_PATH")
if echo "$saved_content" | jq empty 2>/dev/null; then
    assert_pass "Saved profile is valid JSON"
else
    assert_fail "Saved profile is valid JSON"
fi

# Verify values were preserved
retrieved_project=$(echo "$saved_content" | jq -r '.project_name')
assert_eq "Saved project_name preserved" "savetest" "$retrieved_project"

retrieved_max=$(echo "$saved_content" | jq -r '.quality.max_pr_lines')
assert_eq "Saved quality.max_pr_lines preserved" "600" "$retrieved_max"

# Test invalid profile rejection
invalid_save='{invalid json}'
if qp_save "$invalid_save"; then
    assert_fail "Invalid profile rejected by qp_save"
else
    assert_pass "Invalid profile rejected by qp_save"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_merge
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "qp_merge function"

base='{
  "quality": {"max_pr_lines": 500, "max_files_per_pr": 10},
  "testing": {"philosophy": "test_after"}
}'

updates='{
  "quality": {"max_pr_lines": 750}
}'

merged=$(qp_merge "$base" "$updates")
max_lines=$(echo "$merged" | jq -r '.quality.max_pr_lines')
max_files=$(echo "$merged" | jq -r '.quality.max_files_per_pr')

assert_eq "qp_merge applies updates" "750" "$max_lines"
assert_eq "qp_merge preserves unchanged values" "10" "$max_files"
assert_contains "qp_merge preserves unmodified sections" "$merged" '"philosophy": "test_after"'

# ═══════════════════════════════════════════════════════════════════════════════
# Test: qp_infer_from_repo
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "qp_infer_from_repo function"

# Create a test repo with package.json
echo '{"scripts":{"test":"vitest"}}' > "$TEST_REPO/package.json"

inferred=$(qp_infer_from_repo)
test_cmd=$(echo "$inferred" | jq -r '.test_cmd')
assert_eq "Infers test command from package.json" "npm test" "$test_cmd"

# Test with services directory (microservices)
mkdir -p "$TEST_REPO/services/api"
mkdir -p "$TEST_REPO/services/auth"
rm "$TEST_REPO/package.json"

inferred=$(qp_infer_from_repo)
framework=$(echo "$inferred" | jq -r '.framework')
assert_eq "Infers microservices from directory structure" "microservices" "$framework"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Cache and file-based loading
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Cache behavior"

# Test 1: When file exists, always loads from disk (no caching)
cache_profile='{
  "version": 1,
  "project_name": "cachetest",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {},
  "testing": {},
  "quality": {"max_pr_lines": 100},
  "review": {},
  "scope": {},
  "deployment": {}
}'

echo "$cache_profile" > "$QUALITY_PROFILE_PATH"
qp_clear_cache

first=$(load_quality_profile)
first_max=$(echo "$first" | jq -r '.quality.max_pr_lines')
assert_eq "First load gets correct value" "100" "$first_max"

# Modify file
modified_profile='{
  "version": 1,
  "project_name": "cachetest",
  "generated_at": "2026-03-10T00:00:00Z",
  "architecture": {},
  "testing": {},
  "quality": {"max_pr_lines": 200},
  "review": {},
  "scope": {},
  "deployment": {}
}'

echo "$modified_profile" > "$QUALITY_PROFILE_PATH"

# File-based profiles always reload from disk (not cached)
third=$(load_quality_profile)
third_max=$(echo "$third" | jq -r '.quality.max_pr_lines')
assert_eq "File-based profile reloads from disk even without explicit clear" "200" "$third_max"

# Test 2: When file doesn't exist, default profile is cached
rm -f "$QUALITY_PROFILE_PATH"
qp_clear_cache

# First call generates default and caches it
default1=$(load_quality_profile)
default1_name=$(echo "$default1" | jq -r '.project_name')

# Second call returns cached copy (same reference)
default2=$(load_quality_profile)
default2_name=$(echo "$default2" | jq -r '.project_name')

assert_eq "Default profile is consistent across calls" "$default1_name" "$default2_name"

# After cache clear, regenerates default
qp_clear_cache
default3=$(load_quality_profile)
assert_contains "After clear, default regenerated with new timestamp" "$default3" '"generated_at"'

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
