#\!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-adversarial-review-test.sh — Adversarial Review Stage Tests         ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Adversarial Review Tests"

setup_test_env "sw-adversarial-review-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

# Setup test environment
export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
export PROJECT_ROOT="$TEST_TEMP_DIR/repo"
export BASE_BRANCH="main"
export SCRIPT_DIR="$SCRIPT_DIR"
export ISSUE_NUMBER="123"
mkdir -p "$ARTIFACTS_DIR"
mkdir -p "$PROJECT_ROOT/.claude"

mock_git
mock_gh
mock_claude

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Review prompt contains SKEPTICAL framing
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Review prompt structure"

review_prompt="You are a SKEPTICAL senior engineer reviewing code for production.
Your job is to FIND PROBLEMS, not confirm quality."

assert_contains "Review prompt has SKEPTICAL" "$review_prompt" "SKEPTICAL"
assert_contains "Review prompt has FIND PROBLEMS" "$review_prompt" "FIND PROBLEMS"
assert_pass "Review prompt has adversarial framing"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Quality profile injection into review prompt
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Quality profile injection"

cat > "$PROJECT_ROOT/.claude/quality-profile.json" << 'EOF'
{
  "quality": {
    "never_ship": [
      "console.log",
      "debugger",
      "eval("
    ],
    "always_require": [
      "Error handling",
      "Input validation"
    ]
  },
  "review": {
    "focus_areas": [
      "Security vulnerabilities",
      "Race conditions"
    ]
  }
}
EOF

quality_profile="$PROJECT_ROOT/.claude/quality-profile.json"
if [[ -f "$quality_profile" ]]; then
    never_ship=$(jq -r '.quality.never_ship[]? // empty' "$quality_profile" 2>/dev/null | head -1)
    assert_contains "Quality profile has never_ship rules" "$never_ship" "console.log"
    assert_pass "Quality profile loaded for injection"
else
    assert_fail "Quality profile not found"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Acceptance criteria injection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Acceptance criteria injection"

cat > "$ARTIFACTS_DIR/acceptance-criteria.json" << 'EOF'
{
  "acceptance_criteria": [
    "API endpoint returns 200 on valid request",
    "Error responses include descriptive messages",
    "Rate limiting is enforced"
  ]
}
EOF

ac_file="$ARTIFACTS_DIR/acceptance-criteria.json"
if [[ -f "$ac_file" ]]; then
    ac_first=$(jq -r '.acceptance_criteria[0]' "$ac_file" 2>/dev/null)
    assert_contains "First AC present" "$ac_first" "200"
    assert_pass "Acceptance criteria present for injection"
else
    assert_fail "Acceptance criteria file not found"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Scope report injection
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Scope report injection"

cat > "$ARTIFACTS_DIR/scope-report.json" << 'EOF'
{
  "planned_files": [
    "src/api.js",
    "test/api.test.js"
  ],
  "unplanned_files": [
    "README.md"
  ]
}
EOF

scope_file="$ARTIFACTS_DIR/scope-report.json"
if [[ -f "$scope_file" ]]; then
    planned_count=$(jq '.planned_files | length' "$scope_file" 2>/dev/null)
    assert_eq "Planned files count" "2" "$planned_count"
    unplanned_count=$(jq '.unplanned_files | length' "$scope_file" 2>/dev/null)
    assert_eq "Unplanned files count" "1" "$unplanned_count"
    assert_pass "Scope report present for injection"
else
    assert_fail "Scope report not found"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Bug count now blocks (not just critical)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Bug blocking in review"

cat > "$ARTIFACTS_DIR/review.md" << 'EOF'
# Code Review

- **[Bug]** file.js:42 — Off-by-one error in loop
- **[Bug]** auth.js:15 — Race condition on concurrent writes

Review clean — bugs found but no critical issues.
EOF

review_file="$ARTIFACTS_DIR/review.md"
bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$review_file" 2>/dev/null || echo "0")

assert_eq "Bug count extracted correctly" "2" "$bug_count"
assert_gt "Bug count is blocking" "$bug_count" "0"
assert_pass "Bug count now blocks (component requirement)"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Critical + Bug + Security combined for blocking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Combined blocking criteria"

cat > "$ARTIFACTS_DIR/review.md" << 'EOF'
# Code Review

- **[Critical]** api.js:10 — SQL injection vulnerability
- **[Bug]** handler.js:25 — Missing error handling
- **[Security]** auth.js:50 — Hardcoded credentials

Three types of blocking issues detected.
EOF

critical_count=$(grep -ciE '\*\*\[?Critical\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")
bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")
security_count=$(grep -ciE '\*\*\[?Security\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")

blocking=$((critical_count + bug_count + security_count))

assert_eq "Critical count" "1" "$critical_count"
assert_eq "Bug count" "1" "$bug_count"
assert_eq "Security count" "1" "$security_count"
assert_eq "Total blocking issues" "3" "$blocking"
assert_pass "All three severities block (spec requirement)"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Minimum issues to find requirement
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Minimum issues requirement"

cat > "$ARTIFACTS_DIR/review.md" << 'EOF'
# Code Review

- **[Warning]** style.js:5 — Inconsistent naming
- **[Suggestion]** config.js:12 — Consider caching result
- **[Bug]** parser.js:100 — Incomplete error handling
- **[Warning]** utils.js:80 — Unused variable

Found 4 issues, meeting the minimum requirement.
EOF

warning_count=$(grep -ciE '\*\*\[?Warning\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")
bug_count=$(grep -ciE '\*\*\[?Bug\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")
suggestion_count=$(grep -ciE '\*\*\[?Suggestion\]?\*\*' "$ARTIFACTS_DIR/review.md" 2>/dev/null || echo "0")
total_issues=$((warning_count + bug_count + suggestion_count))

assert_gt "Total issues meets minimum" "$total_issues" "2"
assert_pass "Review must find at least 3 issues (spec)"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: DoD scorecard library exists and sources properly
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Compound quality stage ordering"

if [[ -f "$SCRIPT_DIR/lib/dod-scorecard.sh" ]]; then
    assert_pass "dod-scorecard.sh library exists"
else
    assert_fail "dod-scorecard.sh library not found"
fi

if grep -q "dod-scorecard.sh" "$SCRIPT_DIR/lib/pipeline-stages-review.sh"; then
    assert_pass "pipeline-stages-review.sh sources dod-scorecard.sh"
else
    assert_fail "pipeline-stages-review.sh does not source dod-scorecard.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: Review prompt enforces all mandatory sections
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Review prompt mandatory sections"

prompt_file="$ARTIFACTS_DIR/.review-prompt-template.txt"
cat > "$prompt_file" << 'EOF'
Find at least 3 issues. If truly zero issues exist, explain why.
Check EVERY acceptance criterion.
Flag every unplanned file.
Check every never-ship rule.
Verify all always-require rules.
EOF

assert_contains "Prompt includes 3 issues requirement" "$(cat "$prompt_file")" "3 issues"
assert_contains "Prompt includes acceptance criteria check" "$(cat "$prompt_file")" "acceptance criterion"
assert_contains "Prompt includes unplanned files check" "$(cat "$prompt_file")" "unplanned"
assert_contains "Prompt includes never-ship check" "$(cat "$prompt_file")" "never-ship"
assert_contains "Prompt includes always-require check" "$(cat "$prompt_file")" "always-require"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: DoD scorecard prevents LLM review when machine checks fail
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "DoD scorecard blocking mechanism"

if source "$SCRIPT_DIR/lib/dod-scorecard.sh" 2>/dev/null; then
    # Test failing scorecard
    failing_scorecard='{"scorecard": {"pr_size": {"status": "fail", "value": 500, "limit": 50}}, "overall": "fail", "blocking_failures": ["pr_size"]}'
    
    if scorecard_passed "$failing_scorecard"; then
        assert_fail "scorecard_passed should reject failing scorecard"
    else
        assert_pass "scorecard_passed correctly rejects failing scorecard"
    fi

    # Test passing scorecard
    passing_scorecard='{"overall": "pass", "blocking_failures": []}'
    
    if scorecard_passed "$passing_scorecard"; then
        assert_pass "scorecard_passed accepts passing scorecard"
    else
        assert_fail "scorecard_passed should accept passing scorecard"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Print results
# ═══════════════════════════════════════════════════════════════════════════════
print_test_results
