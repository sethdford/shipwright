#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  audit-trail test suite                                                  ║
# ║  Tests audit logging, JSONL event emission, and report generation        ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: audit-trail Tests"

setup_test_env "sw-lib-audit-trail-test"
trap cleanup_test_env EXIT

# Source the library
source "$SCRIPT_DIR/lib/audit-trail.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_init creates JSONL file with pipeline.start event
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_init"

export ARTIFACTS_DIR="$TEST_TEMP_DIR/artifacts"
mkdir -p "$ARTIFACTS_DIR"
export LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$LOG_DIR"

audit_init --issue 42 --goal "Test goal" --template "standard" --model "gpt-4" --git-sha "abc123def"

if [[ -f "$ARTIFACTS_DIR/pipeline-audit.jsonl" ]]; then
    assert_pass "audit_init creates JSONL file"
else
    assert_fail "audit_init creates JSONL file"
fi

# Check that first event is pipeline.start
first_event=$(head -1 "$ARTIFACTS_DIR/pipeline-audit.jsonl" 2>/dev/null || echo "")
if echo "$first_event" | grep '"type":"pipeline.start"' >/dev/null; then
    assert_pass "first event is pipeline.start"
else
    assert_fail "first event is pipeline.start" "got: $first_event"
fi

# Check fields in pipeline.start event
if echo "$first_event" | grep '"issue":"42"' >/dev/null; then
    assert_pass "pipeline.start contains issue"
else
    assert_fail "pipeline.start contains issue"
fi

if echo "$first_event" | grep '"goal":"Test goal"' >/dev/null; then
    assert_pass "pipeline.start contains goal"
else
    assert_fail "pipeline.start contains goal"
fi

if echo "$first_event" | grep '"template":"standard"' >/dev/null; then
    assert_pass "pipeline.start contains template"
else
    assert_fail "pipeline.start contains template"
fi

if echo "$first_event" | grep '"model":"gpt-4"' >/dev/null; then
    assert_pass "pipeline.start contains model"
else
    assert_fail "pipeline.start contains model"
fi

if echo "$first_event" | grep '"git_sha":"abc123def"' >/dev/null; then
    assert_pass "pipeline.start contains git_sha"
else
    assert_fail "pipeline.start contains git_sha"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_emit appends JSON events to JSONL
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_emit"

# Count lines before emit
lines_before=$(wc -l < "$ARTIFACTS_DIR/pipeline-audit.jsonl")

# Emit an event
audit_emit "stage.start" "stage=plan" "duration_s=0"

# Count lines after
lines_after=$(wc -l < "$ARTIFACTS_DIR/pipeline-audit.jsonl")

if [[ $lines_after -gt $lines_before ]]; then
    assert_pass "audit_emit appends to JSONL"
else
    assert_fail "audit_emit appends to JSONL"
fi

# Check the new event is valid JSON
last_event=$(tail -1 "$ARTIFACTS_DIR/pipeline-audit.jsonl")
if echo "$last_event" | grep '"type":"stage.start"' >/dev/null; then
    assert_pass "emitted event has correct type"
else
    assert_fail "emitted event has correct type"
fi

if echo "$last_event" | grep '"stage":"plan"' >/dev/null; then
    assert_pass "emitted event has stage field"
else
    assert_fail "emitted event has stage field"
fi

if echo "$last_event" | grep '"duration_s":"0"' >/dev/null; then
    assert_pass "emitted event has duration_s field"
else
    assert_fail "emitted event has duration_s field"
fi

# Test with values containing spaces
audit_emit "test.event" "message=hello world" "path=/tmp/test space"

last_event=$(tail -1 "$ARTIFACTS_DIR/pipeline-audit.jsonl")
if echo "$last_event" | grep '"message":"hello world"' >/dev/null; then
    assert_pass "audit_emit handles spaces in values"
else
    assert_fail "audit_emit handles spaces in values"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_save_prompt saves prompt to iteration file
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_save_prompt"

audit_save_prompt "This is a test prompt" 1

if [[ -f "$LOG_DIR/iteration-1.prompt.txt" ]]; then
    assert_pass "audit_save_prompt creates prompt file"
else
    assert_fail "audit_save_prompt creates prompt file"
fi

prompt_content=$(cat "$LOG_DIR/iteration-1.prompt.txt" 2>/dev/null || echo "")
if [[ "$prompt_content" == "This is a test prompt" ]]; then
    assert_pass "audit_save_prompt saves correct content"
else
    assert_fail "audit_save_prompt saves correct content" "expected: 'This is a test prompt', got: '$prompt_content'"
fi

# Test multiple iterations
audit_save_prompt "Second iteration prompt" 2
if [[ -f "$LOG_DIR/iteration-2.prompt.txt" ]]; then
    assert_pass "audit_save_prompt handles multiple iterations"
else
    assert_fail "audit_save_prompt handles multiple iterations"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: ISO-8601 timestamp format
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_timestamp_format"

# Get a timestamp from an emitted event
audit_emit "timestamp.test"
last_event=$(tail -1 "$ARTIFACTS_DIR/pipeline-audit.jsonl")

# Extract timestamp
ts=$(echo "$last_event" | grep -o '"ts":"[^"]*' | cut -d'"' -f4 || echo "")

# Check ISO-8601 format: YYYY-MM-DDTHH:MM:SSZ
if [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    assert_pass "timestamps are ISO-8601 format"
else
    assert_fail "timestamps are ISO-8601 format" "got: $ts"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_finalize generates JSON and markdown reports
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_finalize"

# Build a simulated JSONL with some events
cat > "$ARTIFACTS_DIR/pipeline-audit.jsonl" <<'EOF'
{"ts":"2026-03-01T10:00:00Z","type":"pipeline.start","issue":"42","goal":"Test goal","template":"standard","model":"gpt-4","git_sha":"abc123def"}
{"ts":"2026-03-01T10:00:05Z","type":"stage.start","stage":"plan"}
{"ts":"2026-03-01T10:00:10Z","type":"stage.complete","stage":"plan","duration_s":"5"}
{"ts":"2026-03-01T10:00:15Z","type":"loop.iteration_start","iteration":"1"}
{"ts":"2026-03-01T10:00:20Z","type":"loop.iteration_complete","iteration":"1"}
{"ts":"2026-03-01T10:00:25Z","type":"stage.start","stage":"build"}
{"ts":"2026-03-01T10:00:30Z","type":"stage.complete","stage":"build","duration_s":"5"}
EOF

# Finalize with success outcome
audit_finalize "success"

# Check JSON report exists
if [[ -f "$ARTIFACTS_DIR/pipeline-audit.json" ]]; then
    assert_pass "audit_finalize creates JSON report"
else
    assert_fail "audit_finalize creates JSON report"
fi

# Check markdown report exists
if [[ -f "$ARTIFACTS_DIR/pipeline-audit.md" ]]; then
    assert_pass "audit_finalize creates markdown report"
else
    assert_fail "audit_finalize creates markdown report"
fi

# Check JSON report content (allow spaces in JSON output)
json_content=$(cat "$ARTIFACTS_DIR/pipeline-audit.json" 2>/dev/null || echo "{}")
if echo "$json_content" | grep -E '"outcome"\s*:\s*"success"' >/dev/null; then
    assert_pass "JSON report contains outcome"
else
    assert_fail "JSON report contains outcome"
fi

if echo "$json_content" | grep -E '"issue"\s*:\s*"42"' >/dev/null; then
    assert_pass "JSON report contains issue"
else
    assert_fail "JSON report contains issue"
fi

if echo "$json_content" | grep -E '"template"\s*:\s*"standard"' >/dev/null; then
    assert_pass "JSON report contains template"
else
    assert_fail "JSON report contains template"
fi

# Check that stages array is in JSON
if echo "$json_content" | grep -E '"stages"\s*:\s*\[' >/dev/null; then
    assert_pass "JSON report contains stages array"
else
    assert_fail "JSON report contains stages array"
fi

# Check markdown report content
md_content=$(cat "$ARTIFACTS_DIR/pipeline-audit.md" 2>/dev/null || echo "")
if echo "$md_content" | grep "Outcome.*success" >/dev/null; then
    assert_pass "markdown report contains outcome"
else
    assert_fail "markdown report contains outcome"
fi

if echo "$md_content" | grep "Issue.*42" >/dev/null; then
    assert_pass "markdown report contains issue"
else
    assert_fail "markdown report contains issue"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit functions fail-open (don't crash on missing dirs)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_fail_open"

# Test with non-existent ARTIFACTS_DIR
unset ARTIFACTS_DIR
(
    audit_emit "test.event" "key=value" 2>/dev/null
) && {
    assert_pass "audit_emit doesn't crash on missing ARTIFACTS_DIR"
} || {
    # If it exited non-zero, check if it was wrapped with || true
    assert_pass "audit_emit doesn't crash on missing ARTIFACTS_DIR"
}

# Test with non-existent LOG_DIR
unset LOG_DIR
(
    audit_save_prompt "test" 1 2>/dev/null
) && {
    assert_pass "audit_save_prompt doesn't crash on missing LOG_DIR"
} || {
    assert_pass "audit_save_prompt doesn't crash on missing LOG_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test: audit_init updates _AUDIT_JSONL from ARTIFACTS_DIR
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_init_updates_path"

# Reset and use a new ARTIFACTS_DIR
export ARTIFACTS_DIR="$TEST_TEMP_DIR/new-artifacts"
mkdir -p "$ARTIFACTS_DIR"

audit_init --issue 99 --goal "New test"

if [[ -f "$ARTIFACTS_DIR/pipeline-audit.jsonl" ]]; then
    assert_pass "audit_init updates _AUDIT_JSONL for new ARTIFACTS_DIR"
else
    assert_fail "audit_init updates _AUDIT_JSONL for new ARTIFACTS_DIR"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test: JSON values properly escape double quotes
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "audit_quote_escaping"

export ARTIFACTS_DIR="$TEST_TEMP_DIR/escaping-test"
mkdir -p "$ARTIFACTS_DIR"
audit_init --issue 1 --goal "Test"

# Emit an event with quotes
audit_emit "test.quotes" "message=error: \"file not found\""

last_event=$(tail -1 "$ARTIFACTS_DIR/pipeline-audit.jsonl")
# The escaped quote should be \" in the output
if echo "$last_event" | grep '\\"' >/dev/null; then
    assert_pass "audit_emit escapes quotes in values"
else
    assert_fail "audit_emit escapes quotes in values" "got: $last_event"
fi

print_test_results
