#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/helpers test — Unit tests for shared helper functions     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate

print_test_header "Lib: helpers Tests"

setup_test_env "sw-lib-helpers-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

mock_git

# Source helpers (clear guard to re-source)
_SW_HELPERS_LOADED=""
export EVENTS_FILE="$TEST_TEMP_DIR/home/.shipwright/events.jsonl"
source "$SCRIPT_DIR/lib/helpers.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Output helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Output helpers"

info_output=$(info "test message" 2>&1)
assert_contains "info outputs message" "$info_output" "test message"

success_output=$(success "done" 2>&1)
assert_contains "success outputs message" "$success_output" "done"

warn_output=$(warn "warning" 2>&1)
assert_contains "warn outputs message" "$warn_output" "warning"

error_output=$(error "bad" 2>&1)
assert_contains "error outputs message" "$error_output" "bad"

# ═══════════════════════════════════════════════════════════════════════════════
# Timestamp helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Timestamp helpers"

iso=$(now_iso)
assert_contains_regex "now_iso format" "$iso" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

epoch=$(now_epoch)
assert_contains_regex "now_epoch is numeric" "$epoch" '^[0-9]+$'

# Epoch should be recent (after 2024)
if [[ "$epoch" -gt 1700000000 ]]; then
    assert_pass "now_epoch is a reasonable timestamp"
else
    assert_fail "now_epoch is a reasonable timestamp" "got: $epoch"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# emit_event
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "emit_event"

rm -f "$EVENTS_FILE"
emit_event "test.event" "key1=value1" "key2=42"

assert_file_exists "Events file created" "$EVENTS_FILE"

event_line=$(cat "$EVENTS_FILE")
assert_contains "Event has type" "$event_line" '"type":"test.event"'
assert_contains "Event has string field" "$event_line" '"key1":"value1"'
assert_contains "Event has numeric field" "$event_line" '"key2":42'
assert_contains "Event has timestamp" "$event_line" '"ts":'
assert_contains "Event has epoch" "$event_line" '"ts_epoch":'

# Valid JSON
if echo "$event_line" | jq empty 2>/dev/null; then
    assert_pass "Event line is valid JSON"
else
    assert_fail "Event line is valid JSON" "line: $event_line"
fi

# Multiple events
emit_event "test.event2" "data=hello"
line_count=$(wc -l < "$EVENTS_FILE" | tr -d ' ')
assert_eq "Two events produce two lines" "2" "$line_count"

# Escaped special characters in values
emit_event "test.escape" "msg=hello \"world\""
last_line=$(tail -1 "$EVENTS_FILE")
if echo "$last_line" | jq empty 2>/dev/null; then
    assert_pass "Event with quotes is valid JSON"
else
    assert_fail "Event with quotes is valid JSON" "line: $last_line"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# with_retry
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "with_retry"

# Successful command
if with_retry 3 true 2>/dev/null; then
    assert_pass "with_retry succeeds on first try"
else
    assert_fail "with_retry succeeds on first try"
fi

# Always-failing command
if with_retry 2 false 2>/dev/null; then
    assert_fail "with_retry fails after max attempts"
else
    assert_pass "with_retry fails after 2 attempts"
fi

# Command that succeeds eventually (use a counter file)
counter_file="$TEST_TEMP_DIR/retry_counter"
echo "0" > "$counter_file"
flaky_cmd() {
    local count
    count=$(cat "$counter_file")
    count=$((count + 1))
    echo "$count" > "$counter_file"
    [[ "$count" -ge 2 ]]
}
if with_retry 3 flaky_cmd 2>/dev/null; then
    assert_pass "with_retry succeeds on second attempt"
    final_count=$(cat "$counter_file")
    assert_eq "Flaky command ran exactly 2 times" "2" "$final_count"
else
    assert_fail "with_retry succeeds on second attempt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# validate_json
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "validate_json"

# Valid JSON
echo '{"valid": true}' > "$TEST_TEMP_DIR/good.json"
if validate_json "$TEST_TEMP_DIR/good.json" 2>/dev/null; then
    assert_pass "validate_json passes for valid JSON"
else
    assert_fail "validate_json passes for valid JSON"
fi
assert_file_exists "Backup created" "$TEST_TEMP_DIR/good.json.bak"

# Invalid JSON with valid backup
echo '{"valid": true}' > "$TEST_TEMP_DIR/corrupt.json.bak"
echo 'NOT JSON {{{' > "$TEST_TEMP_DIR/corrupt.json"
if validate_json "$TEST_TEMP_DIR/corrupt.json" 2>/dev/null; then
    assert_pass "validate_json recovers from backup"
    recovered=$(cat "$TEST_TEMP_DIR/corrupt.json")
    assert_contains "Recovered content is valid" "$recovered" '"valid"'
else
    assert_fail "validate_json recovers from backup"
fi

# Invalid JSON with no backup
echo 'NOT JSON' > "$TEST_TEMP_DIR/nobackup.json"
rm -f "$TEST_TEMP_DIR/nobackup.json.bak"
if validate_json "$TEST_TEMP_DIR/nobackup.json" 2>/dev/null; then
    assert_fail "validate_json fails with no backup"
else
    assert_pass "validate_json fails for corrupt JSON with no backup"
fi

# Non-existent file is OK
if validate_json "$TEST_TEMP_DIR/nonexistent.json" 2>/dev/null; then
    assert_pass "validate_json passes for non-existent file"
else
    assert_fail "validate_json passes for non-existent file"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# rotate_jsonl
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "rotate_jsonl"

# File under max_lines — no change
rotate_file="$TEST_TEMP_DIR/rotate_test.jsonl"
for i in $(seq 1 5); do echo "{\"line\":$i}" >> "$rotate_file"; done
rotate_jsonl "$rotate_file" 10
line_count=$(wc -l < "$rotate_file" | tr -d ' ')
assert_eq "Under-limit file not rotated" "5" "$line_count"

# File over max_lines — trimmed to max
for i in $(seq 6 25); do echo "{\"line\":$i}" >> "$rotate_file"; done
rotate_jsonl "$rotate_file" 10
line_count=$(wc -l < "$rotate_file" | tr -d ' ')
assert_eq "Over-limit file rotated to 10 lines" "10" "$line_count"

# Keeps most recent lines
last_line=$(tail -1 "$rotate_file")
assert_contains "Keeps most recent lines" "$last_line" '"line":25'

# Non-existent file is OK
rotate_jsonl "$TEST_TEMP_DIR/nonexistent.jsonl" 100
assert_pass "rotate_jsonl handles nonexistent file"

# ═══════════════════════════════════════════════════════════════════════════════
# Project identity helpers
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "Project identity"

# _sw_github_repo fallback
export SHIPWRIGHT_GITHUB_REPO="testowner/testrepo"
result=$(_sw_github_repo)
# With mock git that returns "https://github.com/testuser/testrepo.git"
assert_contains "github_repo extracts from remote" "$result" "/"

# _sw_github_owner
owner=$(_sw_github_owner)
if [[ -n "$owner" ]]; then
    assert_pass "_sw_github_owner returns non-empty: $owner"
else
    assert_fail "_sw_github_owner returns non-empty"
fi

# _sw_docs_url
docs=$(_sw_docs_url)
assert_contains "_sw_docs_url contains github.io" "$docs" "github.io"

# _sw_github_url
url=$(_sw_github_url)
assert_contains "_sw_github_url contains github.com" "$url" "github.com"

unset SHIPWRIGHT_GITHUB_REPO

print_test_results
