#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/daemon-triage test — Unit tests for triage scoring       ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: daemon-triage Tests"

setup_test_env "sw-lib-daemon-triage-test"
trap cleanup_test_env EXIT

# Set up env
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
export STATE_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon-state.json"
export LOG_FILE="$TEST_TEMP_DIR/home/.shipwright/daemon.log"
export REPO_DIR="$TEST_TEMP_DIR/project"
export NO_GITHUB=true
export PIPELINE_TEMPLATE="standard"
export AUTO_TEMPLATE="true"
export INTELLIGENCE_ENABLED=false
export COMPOSER_ENABLED=false
export TEMPLATE_MAP='"{}"'

# shellcheck disable=SC2034
DAEMON_LOG_WRITE_COUNT=0
touch "$LOG_FILE"
mock_git
mock_gh

# Provide stubs
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_epoch() { date +%s; }
emit_event() { :; }
daemon_log() { :; }
info() { echo -e "▸ $*"; }
success() { echo -e "✓ $*"; }
warn() { echo -e "⚠ $*"; }
error() { echo -e "✗ $*" >&2; }

# Source the lib
_DAEMON_TRIAGE_LOADED=""
source "$SCRIPT_DIR/lib/daemon-triage.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# extract_issue_dependencies
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "extract_issue_dependencies"

result=$(extract_issue_dependencies "This depends on #42 and depends on #43")
assert_contains "Extracts depends-on refs" "$result" "#42"
assert_contains "Extracts second depends-on ref" "$result" "#43"

result=$(extract_issue_dependencies "blocked by #10")
assert_contains "Extracts blocked-by ref" "$result" "#10"

result=$(extract_issue_dependencies "Complete after #99")
assert_contains "Extracts after ref" "$result" "#99"

result=$(extract_issue_dependencies "No dependencies here")
assert_eq "No deps returns empty" "" "$result"

result=$(extract_issue_dependencies "depends on #5 depends on #5")
# Should deduplicate
lines=$(echo "$result" | grep -c '#5' || true)
assert_eq "Deduplicates refs" "1" "$lines"

# ═══════════════════════════════════════════════════════════════════════════════
# triage_score_issue — Priority Labels
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "triage_score_issue — Priority"

# Helper to build issue JSON
make_issue() {
    local num="$1" title="$2" body="${3:-}" labels="${4:-}"
    local labels_json="[]"
    if [[ -n "$labels" ]]; then
        labels_json=$(echo "$labels" | tr ',' '\n' | jq -R '.' | jq -s '[.[] | {name: .}]')
    fi
    jq -n \
        --argjson num "$num" \
        --arg title "$title" \
        --arg body "$body" \
        --argjson labels "$labels_json" \
        '{number: $num, title: $title, body: $body, labels: $labels, createdAt: "2026-02-17T00:00:00Z"}'
}

# Urgent label — 30 priority points
issue=$(make_issue 1 "Urgent fix" "Fix now" "urgent")
score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score=$(printf '%s' "$score" | tr -cd '[:digit:]')
assert_gt "Urgent issue scores high" "${score:-0}" 25

# High priority
issue=$(make_issue 2 "High priority" "Important" "high")
score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score=$(printf '%s' "$score" | tr -cd '[:digit:]')
assert_gt "High priority scores > 15" "${score:-0}" 15

# Low priority
issue=$(make_issue 3 "Low priority" "Not urgent" "low")
score_low=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_low=$(printf '%s' "$score_low" | tr -cd '[:digit:]')

# No labels (baseline)
issue=$(make_issue 4 "Normal task" "Do something")
score_none=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_none=$(printf '%s' "$score_none" | tr -cd '[:digit:]')

# Low should be >= no labels
if [[ "${score_low:-0}" -ge "${score_none:-0}" ]]; then
    assert_pass "Low priority >= no labels"
else
    assert_fail "Low priority >= no labels" "low=$score_low, none=$score_none"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# triage_score_issue — Complexity
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "triage_score_issue — Complexity"

# Short body (simple) — gets 20 complexity points
issue=$(make_issue 5 "Simple task" "Fix typo")
score_simple=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_simple=$(printf '%s' "$score_simple" | tr -cd '[:digit:]')

# Long body with many file refs (complex) — gets 0 complexity points
long_body="This is a complex task that requires changes across many files.
Changes needed in src/auth.ts, src/api.ts, src/db.ts, src/models.ts, 
src/routes.ts, src/middleware.ts, src/validators.ts, src/config.ts,
and many other files. The scope is very large and involves
refactoring the entire authentication system with new OAuth providers,
database schema changes, API versioning, and backward compatibility."
issue=$(make_issue 6 "Complex refactor" "$long_body")
score_complex=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_complex=$(printf '%s' "$score_complex" | tr -cd '[:digit:]')

if [[ "${score_simple:-0}" -gt "${score_complex:-0}" ]]; then
    assert_pass "Simple task scores higher than complex (simple=$score_simple, complex=$score_complex)"
else
    assert_fail "Simple task scores higher than complex" "simple=$score_simple, complex=$score_complex"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# triage_score_issue — Type bonus
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "triage_score_issue — Type"

# Security label gets type bonus
issue=$(make_issue 7 "Security fix" "Fix vuln" "security")
score_sec=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_sec=$(printf '%s' "$score_sec" | tr -cd '[:digit:]')

# Bug label gets type bonus
issue=$(make_issue 8 "Bug fix" "Fix crash" "bug")
score_bug=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_bug=$(printf '%s' "$score_bug" | tr -cd '[:digit:]')

# Feature gets smaller bonus
issue=$(make_issue 9 "New feature" "Add widget" "feature")
score_feat=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score_feat=$(printf '%s' "$score_feat" | tr -cd '[:digit:]')

assert_gt "Security score > 0" "${score_sec:-0}" 0
assert_gt "Bug score > 0" "${score_bug:-0}" 0

# ═══════════════════════════════════════════════════════════════════════════════
# triage_score_issue — Score bounds
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "triage_score_issue — Score bounds"

# Score should always be 0-100
issue=$(make_issue 10 "Test bounds" "Test" "urgent,security,bug")
score=$(triage_score_issue "$issue" 2>/dev/null | tail -1)
score=$(printf '%s' "$score" | tr -cd '[:digit:]')
if [[ "${score:-0}" -ge 0 && "${score:-101}" -le 100 ]]; then
    assert_pass "Score within 0-100 bounds ($score)"
else
    assert_fail "Score within 0-100 bounds" "got: $score"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# select_pipeline_template — Label overrides
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "select_pipeline_template"

# Hotfix label
result=$(select_pipeline_template "hotfix,bug" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Hotfix label → hotfix template" "hotfix" "$result"

# Security label
result=$(select_pipeline_template "security,bug" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Security label → enterprise template" "enterprise" "$result"

# Incident label
result=$(select_pipeline_template "incident" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Incident label → hotfix template" "hotfix" "$result"

# Score-based (no special labels)
result=$(select_pipeline_template "enhancement" 75 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "High score → fast template" "fast" "$result"

result=$(select_pipeline_template "enhancement" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Medium score → standard template" "standard" "$result"

result=$(select_pipeline_template "enhancement" 30 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Low score → full template" "full" "$result"

# Auto-template disabled
AUTO_TEMPLATE=false
result=$(select_pipeline_template "enhancement" 90 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Auto-template disabled → default" "$PIPELINE_TEMPLATE" "$result"
AUTO_TEMPLATE=true

# ═══════════════════════════════════════════════════════════════════════════════
# select_pipeline_template — Quality memory
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "select_pipeline_template — Quality memory"

mkdir -p "$HOME/.shipwright/optimization"

# Mock git for repo hash
mock_binary "git" 'case "${1:-}" in
    rev-parse) echo "/tmp/mock-repo" ;;
    *) echo "" ;;
esac
exit 0'

# Critical findings → enterprise
repo_hash=$( echo "/tmp/mock-repo" | shasum -a 256 | cut -c1-16)
quality_file="$HOME/.shipwright/optimization/quality-scores.jsonl"
# shellcheck disable=SC2034
for i in 1 2 3 4 5; do
    echo "{\"repo\":\"$repo_hash\",\"quality_score\":50,\"findings\":{\"critical\":1}}" >> "$quality_file"
done
result=$(select_pipeline_template "enhancement" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Critical quality findings → enterprise" "enterprise" "$result"

# Clean up quality scores
rm -f "$quality_file"

# ═══════════════════════════════════════════════════════════════════════════════
# select_pipeline_template — Template weights
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "select_pipeline_template — Template weights"

cat > "$HOME/.shipwright/optimization/template-weights.json" <<'JSON'
{"weights":{"fast":{"success_rate":0.9,"sample_size":10},"standard":{"success_rate":0.7,"sample_size":5}}}
JSON
result=$(select_pipeline_template "enhancement" 50 2>/dev/null | tail -1)
result=$(printf '%s' "$result" | tr -cd '[:alnum:]-')
assert_eq "Template weights → best template (fast)" "fast" "$result"

rm -f "$HOME/.shipwright/optimization/template-weights.json"

# ═══════════════════════════════════════════════════════════════════════════════
# is_synthetic_issue
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "is_synthetic_issue — shipped default pattern"

SYNTHETIC_ISSUE='{"number":1,"title":"E2E test: add comment","body":"[automated] smoke run","labels":[{"name":"automated"}]}'
HUMAN_E2E_ISSUE='{"number":2,"title":"E2E test: fix timeout in user flow","body":"The login flow times out","labels":[{"name":"bug"}]}'

unset SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS 2>/dev/null || true

rc=0; result=$(is_synthetic_issue "$SYNTHETIC_ISSUE") || rc=$?
assert_exit_code "Marked E2E test issue classified synthetic" 0 "$rc"
assert_eq "Matched pattern name is reported" "e2e-test-comment" "$result"

rc=0; is_synthetic_issue "$HUMAN_E2E_ISSUE" >/dev/null || rc=$?
assert_exit_code "Human issue titled 'E2E test' is NOT synthetic (AND semantics)" 1 "$rc"

# Each AND term is load-bearing: drop one signal at a time, expect no match.
rc=0; is_synthetic_issue '{"number":3,"title":"E2E test: x","body":"[automated]","labels":[]}' >/dev/null || rc=$?
assert_exit_code "Missing required label defeats the match" 1 "$rc"

rc=0; is_synthetic_issue '{"number":4,"title":"E2E test: x","body":"manual","labels":[{"name":"automated"}]}' >/dev/null || rc=$?
assert_exit_code "Missing body marker defeats the match" 1 "$rc"

rc=0; is_synthetic_issue '{"number":5,"title":"Refactor auth","body":"[automated]","labels":[{"name":"automated"}]}' >/dev/null || rc=$?
assert_exit_code "Non-matching title defeats the match" 1 "$rc"

print_test_section "is_synthetic_issue — malformed input"

for bad_input in '{}' 'not json' '' '[]' 'null'; do
    rc=0; is_synthetic_issue "$bad_input" >/dev/null || rc=$?
    assert_exit_code "Malformed input '${bad_input:-<empty>}' is not synthetic" 1 "$rc"
done

print_test_section "is_synthetic_issue — pattern edge cases"

# A pattern with no criteria must match nothing — an all-wildcard pattern would
# quarantine the entire backlog.
export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='[{},{"name":"nameonly"},{"name":"empties","labels":[],"authors":[]}]'
rc=0; is_synthetic_issue '{"number":6,"title":"anything","body":"anything"}' >/dev/null || rc=$?
assert_exit_code "Criteria-less patterns match nothing" 1 "$rc"

export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='[]'
rc=0; is_synthetic_issue "$SYNTHETIC_ISSUE" >/dev/null || rc=$?
assert_exit_code "Empty pattern list disables classification" 1 "$rc"

export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='{"not":"an array"}'
rc=0; is_synthetic_issue "$SYNTHETIC_ISSUE" >/dev/null || rc=$?
assert_exit_code "Non-array pattern config is ignored" 1 "$rc"

# OR across patterns: the second pattern is the one that matches.
export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='[{"name":"never","titleRegex":"^ZZZ"},{"name":"bot-author","authors":["shipwright[bot]"]}]'
rc=0; result=$(is_synthetic_issue '{"number":7,"title":"whatever","user":{"login":"shipwright[bot]"}}') || rc=$?
assert_exit_code "OR across patterns — later pattern matches" 0 "$rc"
assert_eq "Reports the pattern that actually matched" "bot-author" "$result"

rc=0; is_synthetic_issue '{"number":8,"title":"whatever","user":{"login":"a-human"}}' >/dev/null || rc=$?
assert_exit_code "Author mismatch is not synthetic" 1 "$rc"

# String labels (gh --jq join form) as well as object labels.
export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='[{"name":"lbl","labels":["automated","ci"]}]'
rc=0; is_synthetic_issue '{"number":9,"title":"x","labels":["automated","ci","bug"]}' >/dev/null || rc=$?
assert_exit_code "All required labels present (string label form)" 0 "$rc"

rc=0; is_synthetic_issue '{"number":10,"title":"x","labels":["automated"]}' >/dev/null || rc=$?
assert_exit_code "Partial label match is not enough (AND over labels)" 1 "$rc"

print_test_section "is_synthetic_issue — invalid regex fails open and logs once"

_BAD_REGEX_LOG="$TEST_TEMP_DIR/bad-regex.log"
daemon_log() { echo "$*" >> "$_BAD_REGEX_LOG"; }
_SW_BAD_REGEX_SEEN=""
export SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS='[{"name":"broken","titleRegex":"[abc"}]'

rc=0; is_synthetic_issue '{"number":11,"title":"anything"}' >/dev/null || rc=$?
assert_exit_code "Invalid regex fails open (treated as real)" 1 "$rc"
rc=0; is_synthetic_issue '{"number":12,"title":"anything else"}' >/dev/null || rc=$?
assert_exit_code "Invalid regex still fails open on second issue" 1 "$rc"

log_lines=$(wc -l < "$_BAD_REGEX_LOG" | tr -d ' ')
assert_eq "Invalid regex warns exactly once, not once per issue" "1" "$log_lines"
daemon_log() { :; }

unset SHIPWRIGHT_TRIAGE_SYNTHETIC_PATTERNS

print_test_results
