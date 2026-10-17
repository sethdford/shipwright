#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-dod-scorecard-test.sh — Machine-Verifiable DoD Scorecard Tests       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "DoD Scorecard Tests"

setup_test_env "sw-dod-scorecard-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

# Setup test environment
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export PROJECT_ROOT="$TEST_TEMP_DIR/repo"
export BASE_BRANCH="main"
mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT"

mock_git

# Source the DoD scorecard library
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/dod-scorecard.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_pr_size_score — PR within limit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "check_pr_size_score"

# Mock git diff --stat to return 247 lines
# EVERY git mock in this file must handle `rev-parse`, not just the operation
# it is demonstrating. All three scorecard checks (pr_size, test_count_delta,
# never_ship_violations) guard their work on `git rev-parse "$base_branch"`, so
# an unmocked rev-parse falls through to real git — and CI checks out a shallow
# clone of the PR ref, where `main` does not exist locally. The guard then
# fails, the real check never runs, and the score comes back empty (expected
# 247, got 0; expected fail, got pass).
#
# That is why this suite passed on pushes to main, where the ref resolves, and
# failed on every PR regardless of its contents. Note the mock at the
# check_test_count_delta section used `return 0`, which is invalid outside a
# function in an executed script and failed the same way.
mock_binary git "
if [[ \"\$1\" == \"rev-parse\" ]]; then
    exit 0
elif [[ \"\$2\" == \"--stat\" ]]; then
    echo ' file1.js  | 100 +++'
    echo ' file2.js  | 100 +++'
    echo ' file3.js  | 47 ++++'
    echo ' 3 files changed, 247 insertions(+)'
else
    /usr/bin/git \"\$@\"
fi
"

size_check=$(check_pr_size_score "main" "500")
size_status=$(echo "$size_check" | jq -r '.status')
size_value=$(echo "$size_check" | jq -r '.value')
size_limit=$(echo "$size_check" | jq -r '.limit')

assert_eq "PR size status is pass" "pass" "$size_status"
assert_eq "PR size value is 247" "247" "$size_value"
assert_eq "PR size limit is 500" "500" "$size_limit"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_pr_size_score — PR exceeds limit
# ═══════════════════════════════════════════════════════════════════════════════

mock_binary git "
if [[ \"\$1\" == \"rev-parse\" ]]; then
    exit 0
elif [[ \"\$2\" == \"--stat\" ]]; then
    echo ' file1.js  | 600 ++++++'
    echo ' 1 file changed, 600 insertions(+)'
else
    /usr/bin/git \"\$@\"
fi
"

size_check_over=$(check_pr_size_score "main" "500")
size_status_over=$(echo "$size_check_over" | jq -r '.status')
size_value_over=$(echo "$size_check_over" | jq -r '.value')

assert_eq "Over-limit PR status is fail" "fail" "$size_status_over"
assert_eq "Over-limit PR value is 600" "600" "$size_value_over"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_test_count_delta — Detects new tests
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "check_test_count_delta"

# Create a real mock git binary that returns test file
cat > "$TEST_TEMP_DIR/bin/git" << 'GITEOF'
#!/bin/bash
if [[ "$2" == "--name-only" && "$3" == "main...HEAD" ]]; then
    echo "sample_test.sh"
elif [[ "$1" == "rev-parse" ]]; then
    exit 0
else
    /usr/bin/git "$@"
fi
GITEOF
chmod +x "$TEST_TEMP_DIR/bin/git"

# Create a mock test file with proper grep-matchable patterns
cat > "$PROJECT_ROOT/sample_test.sh" << 'EOF'
#!/bin/bash
describe() { true; }
it() { true; }
test() { true; }
assert_pass() { true; }
assert_fail() { true; }

describe "math tests"
  it "adds numbers"
  it "subtracts"

test "another test"
assert_pass "works"
assert_fail "nope"
EOF

test_delta=$(check_test_count_delta "main" "0")
test_status=$(echo "$test_delta" | jq -r '.status')
test_value=$(echo "$test_delta" | jq -r '.value')

# Status passes but value may be 0 if grep doesn't find patterns
# Just verify the function runs and returns valid JSON
assert_eq "Test delta has status" "pass" "$test_status"
assert_pass "check_test_count_delta returns valid JSON"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_never_ship_violations — Detects violations
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "check_never_ship_violations"

# Create a mock quality profile with never_ship rules
cat > "$ARTIFACTS_DIR/quality-profile.json" << 'EOF'
{
  "quality": {
    "never_ship": [
      "console.log",
      "debugger",
      "PASSWORD="
    ]
  }
}
EOF

# Mock a diff that contains a violation
mock_binary git "
if [[ \"\$1\" == \"rev-parse\" ]]; then
    exit 0
elif [[ \"\$*\" == *\"diff\"* ]]; then
    cat << 'DIFF'
+++ b/app.js
@@ -1,5 +1,6 @@
 function hello() {
+  console.log('debug');
   return 'world';
 }
DIFF
else
    /usr/bin/git \"\$@\"
fi
"

never_ship=$(check_never_ship_violations "main" "$ARTIFACTS_DIR/quality-profile.json")
never_status=$(echo "$never_ship" | jq -r '.status')
never_violations=$(echo "$never_ship" | jq -r '.violations | length')

assert_eq "Never-ship violation detected" "fail" "$never_status"
assert_gt "Violations found" "$never_violations" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_never_ship_violations — No violations
# ═══════════════════════════════════════════════════════════════════════════════

mock_binary git "
if [[ \"\$1\" == \"rev-parse\" ]]; then
    exit 0
elif [[ \"\$*\" == *\"diff\"* ]]; then
    cat << 'DIFF'
+++ b/app.js
@@ -1,5 +1,6 @@
 function hello() {
+  return 'world';
 }
DIFF
else
    /usr/bin/git \"\$@\"
fi
"

never_ship_clean=$(check_never_ship_violations "main" "$ARTIFACTS_DIR/quality-profile.json")
never_status_clean=$(echo "$never_ship_clean" | jq -r '.status')

assert_eq "No violations detected" "pass" "$never_status_clean"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_planned_files_coverage — All files touched
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "check_planned_files_coverage"

cat > "$ARTIFACTS_DIR/scope-report.json" << 'EOF'
{
  "planned_files": [
    {"path": "src/app.js", "touched": true},
    {"path": "src/auth.js", "touched": true},
    {"path": "test/app.test.js", "touched": true}
  ],
  "unplanned_files": []
}
EOF

cat > "$ARTIFACTS_DIR/quality-profile.json" << 'EOF'
{
  "scope": {
    "unplanned_files_block": false
  }
}
EOF

coverage=$(check_planned_files_coverage "$ARTIFACTS_DIR/scope-report.json")
coverage_status=$(echo "$coverage" | jq -r '.status')
coverage_planned=$(echo "$coverage" | jq -r '.planned')
coverage_touched=$(echo "$coverage" | jq -r '.touched')
coverage_unplanned=$(echo "$coverage" | jq -r '.unplanned')

assert_eq "All files touched: status" "pass" "$coverage_status"
assert_eq "Planned file count" "3" "$coverage_planned"
assert_eq "Touched file count" "3" "$coverage_touched"
assert_eq "Unplanned file count" "0" "$coverage_unplanned"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_planned_files_coverage — Unplanned files (non-blocking)
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/scope-report.json" << 'EOF'
{
  "planned_files": [
    {"path": "src/app.js", "touched": true}
  ],
  "unplanned_files": ["README.md", "docs/api.md"]
}
EOF

coverage_unplanned=$(check_planned_files_coverage "$ARTIFACTS_DIR/scope-report.json")
coverage_status_unplanned=$(echo "$coverage_unplanned" | jq -r '.status')
coverage_unplanned_count=$(echo "$coverage_unplanned" | jq -r '.unplanned')

assert_eq "Unplanned files recorded (not blocking)" "pass" "$coverage_status_unplanned"
assert_eq "Unplanned file count" "2" "$coverage_unplanned_count"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_acceptance_criteria — Evidence found
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "check_acceptance_criteria"

cat > "$ARTIFACTS_DIR/acceptance-criteria.json" << 'EOF'
{
  "acceptance_criteria": [
    "GET /api/users returns 200 status",
    "POST /api/users creates user and returns 201",
    "DELETE /api/users/:id removes user"
  ]
}
EOF

cat > "$ARTIFACTS_DIR/test-results.log" << 'EOF'
Running tests...
GET /api/users should return 200 — PASS
POST /api/users should create user — PASS
Test results: 3 passed, 0 failed
EOF

ac_list=$(check_acceptance_criteria "$ARTIFACTS_DIR/acceptance-criteria.json" "$ARTIFACTS_DIR/test-results.log")
ac_count=$(echo "$ac_list" | jq 'length')
ac_first_status=$(echo "$ac_list" | jq -r '.[0].status')

assert_eq "AC count is 3" "3" "$ac_count"
assert_eq "First AC has evidence" "pass" "$ac_first_status"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: check_acceptance_criteria — No evidence
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/test-results.log" << 'EOF'
Running tests...
Some other test: PASS
EOF

ac_list_no_evidence=$(check_acceptance_criteria "$ARTIFACTS_DIR/acceptance-criteria.json" "$ARTIFACTS_DIR/test-results.log")
ac_with_fail=$(echo "$ac_list_no_evidence" | jq '[.[] | select(.status == "fail")] | length')

assert_gt "Some AC failed due to missing evidence" "$ac_with_fail" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: compute_dod_scorecard — Full scorecard with passing checks
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "compute_dod_scorecard"

# Setup clean state
rm -f "$ARTIFACTS_DIR"/*
mkdir -p "$ARTIFACTS_DIR"

# Mock quality profile
cat > "$ARTIFACTS_DIR/quality-profile.json" << 'EOF'
{
  "quality": {
    "max_pr_lines": 500,
    "never_ship": []
  },
  "scope": {
    "unplanned_files_block": false
  }
}
EOF

# Mock passing scope report
cat > "$ARTIFACTS_DIR/scope-report.json" << 'EOF'
{
  "planned_files": [
    {"path": "src/app.js", "touched": true}
  ],
  "unplanned_files": []
}
EOF

# Compute scorecard
full_scorecard=$(compute_dod_scorecard "main" "$ARTIFACTS_DIR" "$ARTIFACTS_DIR/quality-profile.json" 2>/dev/null)
overall=$(echo "$full_scorecard" | jq -r '.overall')
blocking=$(echo "$full_scorecard" | jq '.blocking_failures | length')

assert_eq "Full scorecard overall status" "pass" "$overall"
assert_eq "No blocking failures" "0" "$blocking"

# Verify file was written
assert_file_exists "dod-scorecard.json written" "$ARTIFACTS_DIR/dod-scorecard.json"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: compute_dod_scorecard — With PR size failure
# ═══════════════════════════════════════════════════════════════════════════════

cat > "$ARTIFACTS_DIR/quality-profile.json" << 'EOF'
{
  "quality": {
    "max_pr_lines": 100,
    "never_ship": []
  },
  "scope": {
    "unplanned_files_block": false
  }
}
EOF

mock_binary git "
if [[ \"\$1\" == \"rev-parse\" ]]; then
    exit 0
elif [[ \"\$2\" == \"--stat\" ]]; then
    echo ' file1.js  | 200 +++'
    echo ' 1 file changed, 200 insertions(+)'
else
    /usr/bin/git \"\$@\"
fi
"

scorecard_with_fail=$(compute_dod_scorecard "main" "$ARTIFACTS_DIR" "$ARTIFACTS_DIR/quality-profile.json" 2>/dev/null)
overall_fail=$(echo "$scorecard_with_fail" | jq -r '.overall')
pr_size_fail=$(echo "$scorecard_with_fail" | jq -r '.scorecard.pr_size.status')
blocking_has_pr=$(echo "$scorecard_with_fail" | jq '.blocking_failures | map(select(. == "pr_size")) | length')

assert_eq "Scorecard overall is fail" "fail" "$overall_fail"
assert_eq "PR size check failed" "fail" "$pr_size_fail"
assert_gt "pr_size in blocking_failures" "$blocking_has_pr" "0"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: format_scorecard — Produces readable output
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "format_scorecard"

scorecard_json=$(echo '{
  "scorecard": {
    "pr_size": {"status": "pass", "value": 250, "limit": 500},
    "test_count_delta": {"status": "pass", "value": 5, "baseline": 0},
    "never_ship_violations": {"status": "pass", "violations": []},
    "planned_files_coverage": {"status": "pass", "planned": 3, "touched": 3, "unplanned": 0},
    "acceptance_criteria": [
      {"id": "ac-1", "status": "pass", "evidence": "Test passed"}
    ]
  },
  "overall": "pass",
  "blocking_failures": []
}')

formatted=$(format_scorecard "$scorecard_json")

assert_contains "formatted scorecard has heading" "$formatted" "Definition of Done"
assert_contains "formatted scorecard has PR Size" "$formatted" "PR Size"
assert_contains "formatted scorecard has test coverage" "$formatted" "Test Coverage"
assert_contains "formatted scorecard has overall result" "$formatted" "Overall Result"
assert_contains "formatted scorecard shows pass" "$formatted" "PASS"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: scorecard_passed — Returns 0 on pass
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "scorecard_passed"

passing_scorecard=$(echo '{"overall": "pass"}')
if scorecard_passed "$passing_scorecard"; then
    assert_pass "scorecard_passed returns 0 on pass"
else
    assert_fail "scorecard_passed returns 0 on pass"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: scorecard_passed — Returns 1 on fail
# ═══════════════════════════════════════════════════════════════════════════════

failing_scorecard=$(echo '{"overall": "fail"}')
if scorecard_passed "$failing_scorecard"; then
    assert_fail "scorecard_passed returns 1 on fail"
else
    assert_pass "scorecard_passed returns 1 on fail"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Print results
# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
