#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  claude usage test — pipeline runs record real tokens and USD            ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
# Regression suite for the cost ledger that logged $0 / 0 tokens for every run:
#   - stages ran claude in text mode, which reports no usage anywhere;
#   - the loop parsed only the --verbose array, not the single result object `-p --output-format json` prints;
#   - the build loop's USD replaced, instead of adding to, the other stages' spend;
#   - cost_record ignored the reported USD and had no PR to join spend to.
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"
sw_test_isolate
setup_test_env "sw-claude-usage-test"
trap 'cleanup_test_env; sw_test_teardown' EXIT

print_test_header "claude usage → cost ledger"

# The shape `claude -p --output-format json` prints (one object).
RESULT_OBJECT='{"type":"result","subtype":"success","is_error":false,"result":"PLAN TEXT","total_cost_usd":0.4321,"usage":{"input_tokens":1200,"cache_read_input_tokens":30000,"cache_creation_input_tokens":800,"output_tokens":2500}}'
# The --verbose shape: an array whose last "result" element holds the totals.
RESULT_ARRAY='[{"type":"system","subtype":"init"},{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":5}}},{"type":"result","result":"ARRAY TEXT","total_cost_usd":0.1,"usage":{"input_tokens":100,"output_tokens":50}}]'

# A fake agent launcher: prints $FAKE_CLAUDE_OUT and records its argv.
cat > "$TEST_TEMP_DIR/bin/fake-agent-exec" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGV_FILE"
printf '%s' "$FAKE_CLAUDE_OUT"
exit "${FAKE_CLAUDE_RC:-0}"
FAKE
chmod +x "$TEST_TEMP_DIR/bin/fake-agent-exec"
export SW_AGENT_EXEC="$TEST_TEMP_DIR/bin/fake-agent-exec"
export FAKE_ARGV_FILE="$TEST_TEMP_DIR/argv.txt"

# shellcheck source=lib/claude-usage.sh
source "$SCRIPT_DIR/lib/claude-usage.sh"
W="$TEST_TEMP_DIR/work"
mkdir -p "$W"

print_test_section "claude_run_json"

TOTAL_INPUT_TOKENS=0; TOTAL_OUTPUT_TOKENS=0; TOTAL_COST_USD=0
export FAKE_CLAUDE_OUT="$RESULT_OBJECT"
claude_run_json "$W/plan.md" "$W/plan.json" "$W/plan.err" --print --model m "the prompt"
assert_eq "result text goes to the output file" "PLAN TEXT" "$(cat "$W/plan.md")"
assert_eq "input tokens include cache reads and writes" "32000" "$TOTAL_INPUT_TOKENS"
assert_eq "output tokens counted" "2500" "$TOTAL_OUTPUT_TOKENS"
assert_eq "reported USD counted" "0.432100" "$TOTAL_COST_USD"
assert_contains "asks claude for JSON output" "$(cat "$FAKE_ARGV_FILE")" "claude --output-format json --print --model m the prompt"

export FAKE_CLAUDE_OUT="$RESULT_ARRAY"
claude_run_json - "$W/v.json" "$W/v.err" -p "x" > "$W/stdout.txt"
assert_eq "'-' prints the result to stdout" "ARRAY TEXT" "$(cat "$W/stdout.txt")"
assert_eq "verbose array: input tokens add up" "32100" "$TOTAL_INPUT_TOKENS"
assert_eq "verbose array: USD adds up across calls" "0.532100" "$TOTAL_COST_USD"

export FAKE_CLAUDE_OUT="Invalid API key · Please run /login"
export FAKE_CLAUDE_RC=1
rc=0
claude_run_json "$W/err.md" "$W/err.json" "$W/err.err" -p "x" || rc=$?
unset FAKE_CLAUDE_RC
assert_eq "non-JSON output passes through unchanged" "Invalid API key · Please run /login" "$(cat "$W/err.md")"
assert_eq "claude's exit status is returned" "1" "$rc"
assert_eq "non-JSON output adds no spend" "0.532100" "$TOTAL_COST_USD"

print_test_section "parse_claude_usage"

printf '%s' "no usage here" > "$W/text.log"
rc=0; parse_claude_usage "$W/text.log" || rc=$?
assert_eq "a text log is not usage (caller falls back)" "1" "$rc"
printf '%s' '{"type":"result","is_error":true,"subtype":"error_max_turns","total_cost_usd":0.25,"usage":{"input_tokens":10,"output_tokens":20}}' > "$W/maxturns.json"
parse_claude_usage "$W/maxturns.json"
assert_eq "a failed turn still costs money" "0.782100" "$TOTAL_COST_USD"

print_test_section "_pipeline_add_loop_tokens (build stage)"

info() { :; }
TOTAL_INPUT_TOKENS=100; TOTAL_OUTPUT_TOKENS=10; TOTAL_COST_USD=0.5
printf '%s' '{"input_tokens":1000,"output_tokens":200,"cost_usd":2.25,"iterations":3}' > "$W/loop-tokens.json"
_pipeline_add_loop_tokens "$W/loop-tokens.json"
assert_eq "loop USD is added to earlier stages, not substituted" "2.750000" "$TOTAL_COST_USD"
assert_eq "loop tokens added" "1100" "$TOTAL_INPUT_TOKENS"
_pipeline_add_loop_tokens "$W/missing.json"
assert_eq "no loop file adds nothing" "2.750000" "$TOTAL_COST_USD"

print_test_section "accumulate_loop_tokens (sw-loop)"

LOOP_INPUT_TOKENS=0; LOOP_OUTPUT_TOKENS=0; LOOP_COST_MILLICENTS=0
printf '%s' "$RESULT_OBJECT" > "$W/iteration-1.json"
accumulate_loop_tokens "$W/iteration-1.json"
assert_eq "result object: input tokens (with cache)" "32000" "$LOOP_INPUT_TOKENS"
assert_eq "result object: output tokens" "2500" "$LOOP_OUTPUT_TOKENS"
assert_eq "result object: reported USD in millicents" "43210" "$LOOP_COST_MILLICENTS"
printf '%s' "$RESULT_ARRAY" > "$W/iteration-2.json"
accumulate_loop_tokens "$W/iteration-2.json"
assert_eq "verbose array still parsed" "53210" "$LOOP_COST_MILLICENTS"

print_test_section "cost_record (sw-cost.sh)"

COSTS="$HOME/.shipwright/costs.json"
bash "$SCRIPT_DIR/sw-cost.sh" record 32000 2500 opus pipeline 42 1.2345 8736 run-77 acme/widgets >/dev/null 2>&1
entry=$(jq -c '.entries[-1]' "$COSTS")
assert_json_key "reported USD is recorded, not re-estimated" "$entry" ".cost_usd" "1.2345"
assert_json_key "cost source says reported" "$entry" ".cost_source" "reported"
assert_json_key "entry names the PR" "$entry" ".pr" "8736"
assert_json_key "entry names the pipeline run" "$entry" ".pipeline_id" "run-77"
assert_json_key "entry names the repo" "$entry" ".repo" "acme/widgets"
assert_json_key "tokens recorded" "$entry" ".input_tokens" "32000"

bash "$SCRIPT_DIR/sw-cost.sh" record 1000000 0 sonnet pipeline 43 >/dev/null 2>&1
entry=$(jq -c '.entries[-1]' "$COSTS")
assert_json_key "without a reported USD the cost is estimated" "$entry" ".cost_source" "estimated"
assert_json_key "estimate uses the model rate" "$entry" ".cost_usd == 3" "true"
assert_json_key "no PR key when the run opened none" "$entry" ".pr" "null"

bash "$SCRIPT_DIR/sw-cost.sh" record "" "n/a" sonnet pipeline 44 0 >/dev/null 2>&1
assert_eq "non-numeric tokens still write an entry" "3" "$(jq '.entries | length' "$COSTS")"

echo ""
print_test_results
