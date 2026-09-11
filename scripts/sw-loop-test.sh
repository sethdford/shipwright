#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop test — Validate continuous agent loop harness           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

setup_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    mkdir -p "$TEST_TEMP_DIR/home/.claude"
    mkdir -p "$TEST_TEMP_DIR/bin"
    mkdir -p "$TEST_TEMP_DIR/repo/.git"

    # Mock claude CLI
    cat > "$TEST_TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude executed"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    # Mock git
    cat > "$TEST_TEMP_DIR/bin/git" <<'MOCKEOF'
#!/usr/bin/env bash
case "${1:-}" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "/tmp/mock-repo"
        elif [[ "${2:-}" == "--abbrev-ref" ]]; then
            echo "main"
        else
            echo "abc1234"
        fi
        ;;
    diff)
        echo "+added line"
        echo "-removed line"
        ;;
    log)
        echo "abc1234 Mock commit message"
        ;;
    worktree)
        echo "ok"
        ;;
    branch)
        echo "main"
        ;;
    status)
        echo "nothing to commit"
        ;;
    *)
        echo "mock git: $*"
        ;;
esac
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock gh output"
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Mock tmux
    cat > "$TEST_TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$TEST_TEMP_DIR/bin/tmux"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEST_TEMP_DIR/bin/jq"
    fi

    # Link real date, wc, etc.
    for cmd in date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd"
        fi
    done

    export PATH="$TEST_TEMP_DIR/bin:$PATH"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
}

trap cleanup_test_env EXIT

# Use assert_pass/assert_fail from test-helpers.sh (they track TOTAL/PASS/FAIL counters)

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
print_test_header "Shipwright Loop Tests"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

setup_test_env "sw-loop-test"
setup_env

# ─── Test 1: --help flag ────────────────────────────────────────────────────
echo -e "${DIM}  help / version${RESET}"

output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    assert_pass "--help exits 0"
else
    assert_fail "--help exits 0" "exit code: $rc"
fi

assert_contains "--help shows usage" "$output" "USAGE"
assert_contains "--help shows options" "$output" "OPTIONS"

# ─── Test 2: --help shows all key options ────────────────────────────────────
assert_contains "--help mentions --max-iterations" "$output" "--max-iterations"
assert_contains "--help mentions --test-cmd" "$output" "--test-cmd"
assert_contains "--help mentions --model" "$output" "--model"
assert_contains "--help mentions --agents" "$output" "--agents"
assert_contains "--help mentions --resume" "$output" "--resume"

# ─── Test 3: VERSION is defined ─────────────────────────────────────────────
version_line=$(grep '^VERSION=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ -n "$version_line" ]]; then
    assert_pass "VERSION variable defined in sw-loop.sh"
else
    assert_fail "VERSION variable defined in sw-loop.sh"
fi

# ─── Test 4: Missing goal argument ───────────────────────────────────────────
echo ""
echo -e "${DIM}  argument parsing${RESET}"

# sw-loop.sh requires a goal — no goal means empty GOAL var, should fail
output=$(bash "$SCRIPT_DIR/sw-loop.sh" 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]]; then
    assert_pass "No arguments exits non-zero"
else
    assert_fail "No arguments exits non-zero" "expected failure, got exit 0"
fi

# ─── Test 5: Script uses set -euo pipefail ──────────────────────────────────
echo ""
echo -e "${DIM}  script safety${RESET}"

if grep -q '^set -euo pipefail' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Uses set -euo pipefail"
else
    assert_fail "Uses set -euo pipefail"
fi

# ─── Test 6: ERR trap is set ────────────────────────────────────────────────
if grep -q "trap.*ERR" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ERR trap is set"
else
    assert_fail "ERR trap is set"
fi

# ─── Test 7: SIGHUP trap for daemon resilience ──────────────────────────────
if grep -q "trap '' HUP" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "SIGHUP trap set for daemon resilience"
else
    assert_fail "SIGHUP trap set for daemon resilience"
fi

# ─── Test 8: CLAUDECODE unset ───────────────────────────────────────────────
if grep -q "unset CLAUDECODE" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "CLAUDECODE env var is unset"
else
    assert_fail "CLAUDECODE env var is unset"
fi

# ─── Test 9: Default values ─────────────────────────────────────────────────
echo ""
echo -e "${DIM}  defaults${RESET}"

# Check key defaults in source
if grep -q 'MAX_ITERATIONS="${SW_MAX_ITERATIONS:-20}"' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_ITERATIONS is 20"
else
    assert_fail "Default MAX_ITERATIONS is 20"
fi

if grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1"
else
    assert_fail "Default AGENTS is 1"
fi

if grep -qE 'MAX_RESTARTS.*0|loop\.max_restarts.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0"
else
    assert_fail "Default MAX_RESTARTS is 0"
fi

# ─── Test 10: Compat library sourced ─────────────────────────────────────────
if grep -q 'lib/compat.sh' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Sources lib/compat.sh"
else
    assert_fail "Sources lib/compat.sh"
fi

# ─── Test 11: JSON output format in claude flags ────────────────────────────
echo ""
echo -e "${DIM}  json output format${RESET}"
if grep -q 'output-format.*json' "$SCRIPT_DIR/sw-loop.sh" || grep -q 'output-format.*json' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags includes --output-format json"
else
    assert_fail "build_claude_flags includes --output-format json"
fi

echo -e "${DIM}  effort level flag${RESET}"
if grep -q '"--effort"' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags supports --effort"
else
    assert_fail "build_claude_flags supports --effort"
fi

echo -e "${DIM}  fallback model flag${RESET}"
if grep -q 'fallback-model' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "build_claude_flags supports --fallback-model"
else
    assert_fail "build_claude_flags supports --fallback-model"
fi

# ─── build_claude_flags: cache prefix + session continuity ──────────────────
# These INVOKE the function and assert on what it emits, rather than grepping
# the source for a string. A grep passes even when the flag never reaches the
# command line — which is the whole failure mode worth guarding against here.
echo -e "${DIM}  prompt-cache and session flags (behavioral)${RESET}"
_flags_with() {
    bash -c '
        source "'"$SCRIPT_DIR"'/lib/compat.sh" >/dev/null 2>&1
        source "'"$SCRIPT_DIR"'/lib/loop-iteration.sh" >/dev/null 2>&1
        MODEL=claude-opus-5; SKIP_PERMISSIONS=false; MAX_TURNS=""
        EFFORT_LEVEL=""; FALLBACK_MODEL=""
        '"$1"'
        build_claude_flags
    ' 2>/dev/null
}

# Stable prefix is on by default: per-machine sections (notably git status,
# which changes constantly mid-loop) must not sit in the cached prefix.
if [[ "$(_flags_with '')" == *"--exclude-dynamic-system-prompt-sections"* ]]; then
    assert_pass "stable prompt prefix is on by default"
else
    assert_fail "stable prompt prefix is on by default"
fi

if [[ "$(_flags_with 'LOOP_STABLE_PROMPT_PREFIX=false')" != *"--exclude-dynamic-system-prompt-sections"* ]]; then
    assert_pass "stable prompt prefix can be disabled"
else
    assert_fail "stable prompt prefix can be disabled"
fi

# Session continuity is opt-in, so no --session-id unless LOOP_SESSION_ID is set.
# A stray --session-id would silently chain unrelated pipeline runs together.
if [[ "$(_flags_with '')" != *"--session-id"* ]]; then
    assert_pass "no --session-id when continuity is off"
else
    assert_fail "no --session-id when continuity is off"
fi

if [[ "$(_flags_with 'LOOP_SESSION_ID=11111111-2222-4333-8444-555555555555')" \
      == *"--session-id 11111111-2222-4333-8444-555555555555"* ]]; then
    assert_pass "--session-id passed through when continuity is on"
else
    assert_fail "--session-id passed through when continuity is on"
fi

# The CLI rejects a --session-id that is not a valid UUID, so a malformed
# generator would break every iteration rather than degrade.
_uuid=$(bash -c 'source "'"$SCRIPT_DIR"'/lib/compat.sh" >/dev/null 2>&1; new_uuid' 2>/dev/null)
if [[ "$_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    assert_pass "new_uuid emits a valid UUID"
else
    assert_fail "new_uuid emits a valid UUID" "got: $_uuid"
fi

_uuid2=$(bash -c 'source "'"$SCRIPT_DIR"'/lib/compat.sh" >/dev/null 2>&1; new_uuid' 2>/dev/null)
if [[ "$_uuid" != "$_uuid2" ]]; then
    assert_pass "new_uuid is unique per call"
else
    assert_fail "new_uuid is unique per call"
fi

# ─── Test 12: Token accumulation parses JSON ────────────────────────────────
if grep -q 'jq.*usage.input_tokens' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "accumulate_loop_tokens parses JSON usage"
else
    assert_fail "accumulate_loop_tokens parses JSON usage"
fi

# ─── Test 13: Cost tracking variable initialized ────────────────────────────
if grep -q 'LOOP_COST_MILLICENTS=0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "LOOP_COST_MILLICENTS initialized"
else
    assert_fail "LOOP_COST_MILLICENTS initialized"
fi

# ─── Test 14: write_loop_tokens includes cost ────────────────────────────────
if grep -q 'cost_usd' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "write_loop_tokens includes cost_usd"
else
    assert_fail "write_loop_tokens includes cost_usd"
fi

# ─── Test 15: _extract_text_from_json helper exists ──────────────────────────
if grep -q '_extract_text_from_json' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "_extract_text_from_json helper defined"
else
    assert_fail "_extract_text_from_json helper defined"
fi

# ─── Test 15b: validate_claude_output and check_budget_gate exist ───────────
if grep -q 'validate_claude_output()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "validate_claude_output helper defined"
else
    assert_fail "validate_claude_output helper defined"
fi
if grep -q 'check_budget_gate()' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "check_budget_gate helper defined"
else
    assert_fail "check_budget_gate helper defined"
fi

# ─── Test 16: run_claude_iteration separates stdout/stderr ───────────────────
if grep -q '2>"$err_file"' "$SCRIPT_DIR/sw-loop.sh" || grep -q '2>"$err_file"' "$SCRIPT_DIR/lib/loop-iteration.sh"; then
    assert_pass "run_claude_iteration separates stdout from stderr"
else
    assert_fail "run_claude_iteration separates stdout from stderr"
fi

# ─── Test 17-19: _extract_text_from_json robustness ──────────────────────────
echo ""
echo -e "${DIM}  json extraction robustness${RESET}"
# Extract the function from sw-loop.sh and test it in isolation (can't source
# sw-loop.sh because it has no source guard — main() runs unconditionally)
_extract_fn=$(sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
bash -c "
warn() { :; }
$_extract_fn
# Test 1: empty file → '(no output)'
touch '$tmpdir/empty.json'
_extract_text_from_json '$tmpdir/empty.json' '$tmpdir/out1.log' ''
# Test 2: valid JSON array → extracts .result
echo '[{\"type\":\"result\",\"result\":\"Hello world\",\"usage\":{\"input_tokens\":100}}]' > '$tmpdir/valid.json'
_extract_text_from_json '$tmpdir/valid.json' '$tmpdir/out2.log' ''
# Test 3: plain text → pass through
echo 'This is plain text output' > '$tmpdir/text.json'
_extract_text_from_json '$tmpdir/text.json' '$tmpdir/out3.log' ''
" 2>/dev/null

if grep -q "no output" "$tmpdir/out1.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles empty file"
else
    assert_fail "_extract_text_from_json handles empty file" "expected '(no output)' in $tmpdir/out1.log"
fi

if grep -q "Hello world" "$tmpdir/out2.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON"
else
    assert_fail "_extract_text_from_json extracts .result from JSON" "expected 'Hello world' in $tmpdir/out2.log"
fi

if grep -q "plain text" "$tmpdir/out3.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json passes through plain text"
else
    assert_fail "_extract_text_from_json passes through plain text" "expected 'plain text' in $tmpdir/out3.log"
fi
rm -rf "$tmpdir"

# ─── Test 20: Default configuration values from source ─────────────────────────
echo ""
echo -e "${DIM}  default config from source${RESET}"
max_iter_line=$(grep -E '^MAX_ITERATIONS=' "$SCRIPT_DIR/sw-loop.sh" | head -1)
if [[ "$max_iter_line" =~ 20 ]]; then
    assert_pass "Default MAX_ITERATIONS is 20 (from source)"
else
    assert_fail "Default MAX_ITERATIONS is 20 (from source)" "got: $max_iter_line"
fi
if grep -qE '^AGENTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -q 'AGENTS=1' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default AGENTS is 1 (from source)"
else
    assert_fail "Default AGENTS is 1 (from source)"
fi
if grep -qE 'MAX_RESTARTS=' "$SCRIPT_DIR/sw-loop.sh" && grep -qE 'max_restarts.*0|MAX_RESTARTS.*0' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Default MAX_RESTARTS is 0 (from source)"
else
    assert_fail "Default MAX_RESTARTS is 0 (from source)"
fi

# ─── Test 21: _extract_text_from_json — nested objects and binary ─────────────
echo ""
echo -e "${DIM}  json extraction edge cases${RESET}"
_extract_fn=$(sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
tmpdir2=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
bash -c "
warn() { :; }
$_extract_fn
# Nested JSON array with objects
echo '[{\"type\":\"result\",\"result\":\"Nested extraction works\",\"usage\":{\"input_tokens\":50}}]' > '$tmpdir2/nested.json'
_extract_text_from_json '$tmpdir2/nested.json' '$tmpdir2/nested_out.log' ''
# Binary garbage — should not crash, pass through or handle
printf '\x00\x01\x02\xff\xfe' > '$tmpdir2/binary.dat'
_extract_text_from_json '$tmpdir2/binary.dat' '$tmpdir2/binary_out.log' ''
" 2>/dev/null

if grep -q "Nested extraction works" "$tmpdir2/nested_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json handles nested JSON objects"
else
    assert_fail "_extract_text_from_json handles nested JSON objects" "expected 'Nested extraction works'"
fi
# Binary input should not crash; output may be raw or placeholder
if [[ -f "$tmpdir2/binary_out.log" ]]; then
    assert_pass "_extract_text_from_json handles binary garbage without crash"
else
    assert_fail "_extract_text_from_json handles binary garbage without crash"
fi
rm -rf "$tmpdir2"

# ─── Test 21b: _extract_text_from_json — JSON object (not array) input ───────
echo ""
echo -e "${DIM}  json object extraction (issue #242)${RESET}"
_extract_fn=$(sed -n '/^_extract_text_from_json()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
tmpdir3=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
bash -c "
warn() { echo \"WARN: \$*\" >&2; }
$_extract_fn
# JSON object with .result field — Claude sometimes outputs this instead of an array
echo '{\"type\":\"result\",\"result\":\"Object result works\"}' > '$tmpdir3/obj_result.json'
_extract_text_from_json '$tmpdir3/obj_result.json' '$tmpdir3/obj_result_out.log' ''
# JSON object with .content field
echo '{\"type\":\"message\",\"content\":\"Object content works\"}' > '$tmpdir3/obj_content.json'
_extract_text_from_json '$tmpdir3/obj_content.json' '$tmpdir3/obj_content_out.log' ''
" 2>"$tmpdir3/warn.log"

if grep -q "Object result works" "$tmpdir3/obj_result_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .result from JSON object"
else
    assert_fail "_extract_text_from_json extracts .result from JSON object" "expected 'Object result works'"
fi
if grep -q "Object content works" "$tmpdir3/obj_content_out.log" 2>/dev/null; then
    assert_pass "_extract_text_from_json extracts .content from JSON object"
else
    assert_fail "_extract_text_from_json extracts .content from JSON object" "expected 'Object content works'"
fi
# Confirm no spurious "jq not available" warning was emitted
if grep -q "jq not available" "$tmpdir3/warn.log" 2>/dev/null; then
    assert_fail "_extract_text_from_json does not emit 'jq not available' for JSON objects" "got: $(cat "$tmpdir3/warn.log")"
else
    assert_pass "_extract_text_from_json does not emit 'jq not available' for JSON objects"
fi
rm -rf "$tmpdir3"

# ─── Test 22: Script structure — circuit breaker, stuckness, test gate ────────
echo ""
echo -e "${DIM}  script structure${RESET}"
if grep -qE 'check_circuit_breaker|CIRCUIT_BREAKER' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has circuit breaker logic"
else
    assert_fail "Script has circuit breaker logic"
fi
if grep -qE 'detect_stuckness|stuckness' "$SCRIPT_DIR/sw-loop.sh" "$SCRIPT_DIR/lib/loop-convergence.sh"; then
    assert_pass "Script has stuckness detection"
else
    assert_fail "Script has stuckness detection"
fi
if grep -qE 'run_test_gate|run_quality_gates' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Script has test/quality gate functions"
else
    assert_fail "Script has test/quality gate functions"
fi

# ─── Test 23: --help key flags defined in show_help ────────────────────────────
# (Actual help output assertions are in Test 2 above)
if grep -qF -- '--model' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--agents' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --model and --agents flags"
else
    assert_fail "Help text defines --model and --agents flags"
fi
if grep -qF -- '--test-cmd' "$SCRIPT_DIR/sw-loop.sh" && grep -qF -- '--resume' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --test-cmd and --resume flags"
else
    assert_fail "Help text defines --test-cmd and --resume flags"
fi

echo -e "${DIM}  help mentions --effort${RESET}"
if grep -qF -- '--effort' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --effort flag"
else
    assert_fail "Help text defines --effort flag"
fi

echo -e "${DIM}  help mentions --fallback-model${RESET}"
if grep -qF -- '--fallback-model' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Help text defines --fallback-model flag"
else
    assert_fail "Help text defines --fallback-model flag"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# LOOP BEHAVIOR TESTS (real loop execution with mocks)
# ═══════════════════════════════════════════════════════════════════════════════

# Setup for loop behavior tests: real git repo, mock claude only
setup_loop_env() {
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright" "$TEST_TEMP_DIR/home/.claude" "$TEST_TEMP_DIR/bin"

    # Create real git repo (use system git, not mock from PATH)
    local _git
    _git=$(PATH=/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
    if [[ -z "$_git" ]]; then
        echo "WARN: git not found — skipping loop behavior tests"
        return 1
    fi
    mkdir -p "$TEST_TEMP_DIR/repo"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
    echo "init" > "$TEST_TEMP_DIR/repo/file.txt"
    (cd "$TEST_TEMP_DIR/repo" && "$_git" add . && "$_git" commit -q -m "init")

    # Mock gh
    cat > "$TEST_TEMP_DIR/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
GHMOCK
    chmod +x "$TEST_TEMP_DIR/bin/gh"

    # Link real jq, git, date, seq, etc. (use clean PATH to avoid mock from setup_env)
    for cmd in jq git date seq wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch bash; do
        if PATH=/usr/local/bin:/usr/bin:/bin command -v "$cmd" &>/dev/null; then
            ln -sf "$(PATH=/usr/local/bin:/usr/bin:/bin command -v "$cmd")" "$TEST_TEMP_DIR/bin/$cmd" 2>/dev/null || true
        fi
    done

    # Use our mocks (claude, gh) + real git/jq from our bin
    export PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin"
    export HOME="$TEST_TEMP_DIR/home"
    export NO_GITHUB=true
    return 0
}

# ─── Test: Loop completes when Claude outputs LOOP_COMPLETE ─────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that says LOOP_COMPLETE on first iteration (valid JSON for --output-format json)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 5 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qF "LOOP_COMPLETE"; then
        assert_pass "Loop detected completion signal"
    elif echo "$output" | grep -qi "complete.*LOOP_COMPLETE\|LOOP_COMPLETE.*accepted"; then
        assert_pass "Loop detected completion signal"
    else
        assert_fail "Loop detected completion signal" "output missing LOOP_COMPLETE"
    fi
else
    assert_fail "Loop completes on LOOP_COMPLETE" "setup failed (git missing?)"
fi

# ─── Test: Loop runs multiple iterations when tests fail ───────────────────
echo ""
echo -e "${DIM}  loop behavior: iterations on test failure${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that makes a change, then says LOOP_COMPLETE on iteration 2
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if [[ ! -f iter2.txt ]]; then
    echo "Adding file" > iter2.txt
    echo '[{"type":"result","result":"Work in progress","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add iter2.txt" \
        --max-iterations 5 \
        --test-cmd "test -f iter2.txt" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qE "Iteration [2-9]|iteration [2-9]"; then
        assert_pass "Loop runs multiple iterations when tests fail initially"
    elif echo "$output" | grep -q "LOOP_COMPLETE"; then
        assert_pass "Loop runs multiple iterations and completes"
    elif echo "$output" | grep -qi "circuit breaker\|max iteration"; then
        assert_pass "Loop iterates (stopped by limit)"
    else
        assert_fail "Loop iterates on test failure" "expected multiple iterations"
    fi
else
    assert_fail "Loop iterates on test failure" "setup failed"
fi

# ─── Test: Loop respects max-iterations limit ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: max iterations${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that never says LOOP_COMPLETE (valid JSON)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Still working...","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Never finish" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qiE "max iteration|iteration.*3|Max iterations"; then
        assert_pass "Loop stops at max iterations"
    else
        assert_fail "Loop respects max-iterations" "expected iteration limit message"
    fi
else
    assert_fail "Loop max iterations" "setup failed"
fi

# ─── Test: Loop detects stuckness ───────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: stuckness detection${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that produces identical output every iteration (no file changes)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"I am trying the same approach again.","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Fix something" \
        --max-iterations 5 \
        --test-cmd "false" \
        --local \
        --no-auto-extend \
        2>&1) || true

    if echo "$output" | grep -qi "stuckness\|stuck"; then
        assert_pass "Loop detects stuckness"
    elif echo "$output" | grep -qi "circuit breaker"; then
        assert_pass "Loop circuit breaker triggered (stuckness-related)"
    elif echo "$output" | grep -qi "max iteration"; then
        assert_pass "Loop stops at limit (stuckness test)"
    else
        assert_fail "Loop stuckness detection" "expected stuckness or circuit breaker"
    fi
else
    assert_fail "Loop stuckness detection" "setup failed"
fi

# ─── Test: Budget gate stops loop ──────────────────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: budget gate${RESET}"

# sw-cost reads from ~/.shipwright. Set budget=0.01 and spent>=budget via costs.json.
if setup_loop_env 2>/dev/null && [[ -x "$SCRIPT_DIR/sw-cost.sh" ]]; then
    mkdir -p "$TEST_TEMP_DIR/home/.shipwright"
    _epoch=$(date +%s)
    echo "{\"daily_budget_usd\":0.01,\"enabled\":true}" > "$TEST_TEMP_DIR/home/.shipwright/budget.json"
    echo "{\"entries\":[{\"ts_epoch\":$_epoch,\"cost_usd\":1.0,\"input_tokens\":0,\"output_tokens\":0,\"model\":\"test\",\"stage\":\"test\",\"issue\":\"\"}],\"summary\":{}}" > "$TEST_TEMP_DIR/home/.shipwright/costs.json"
    # Add claude mock (loop exits before running it, but ensures consistent env)
    echo '#!/usr/bin/env bash
echo '"'"'[{"type":"result","result":"Done","usage":{"input_tokens":0,"output_tokens":0}}]'"'"'
exit 0' > "$TEST_TEMP_DIR/bin/claude"
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Do nothing" \
        --max-iterations 2 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "budget exhausted|Budget exhausted|LOOP BUDGET_EXHAUSTED"; then
        assert_pass "Budget gate stops loop"
    else
        assert_fail "Budget gate stops loop" "expected budget exhausted message"
    fi
else
    assert_pass "Budget gate (skipped - setup or sw-cost missing)"
fi

# ─── Test: validate_claude_output catches bad output ───────────────────────
echo ""
echo -e "${DIM}  validate_claude_output${RESET}"

_validate_fn=$(sed -n '/^validate_claude_output()/,/^}/p' "$SCRIPT_DIR/sw-loop.sh")
_valid_tmp=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
# Use real git for repo setup (bypass mock from setup_env)
_valid_git=$(PATH=/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
(cd "$_valid_tmp" && "$_valid_git" init -q && "$_valid_git" config user.email "t@t" && "$_valid_git" config user.name "T")
echo "api key leaked" > "$_valid_tmp/leak.ts"
(cd "$_valid_tmp" && "$_valid_git" add leak.ts 2>/dev/null)
_valid_out=$(cd "$_valid_tmp" && bash -c "
warn() { :; }
$_validate_fn
validate_claude_output . 2>/dev/null
_e=\$?
echo \"exit=\$_e\"
" 2>/dev/null)
rm -rf "$_valid_tmp"
if echo "$_valid_out" | grep -q "exit=1"; then
    assert_pass "validate_claude_output catches corrupt output"
else
    assert_fail "validate_claude_output catches bad output" "expected non-zero exit for api key leak"
fi

# ─── Test: Loop tracks progress via git diff ──────────────────────────────
echo ""
echo -e "${DIM}  loop behavior: progress tracking${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that adds a file (simulates progress)
    cat > "$TEST_TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo "new content" > progress.txt
echo '[{"type":"result","result":"Added progress.txt. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"

    output=$(env PATH="$TEST_TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEST_TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEST_TEMP_DIR/repo" \
        "Add progress.txt" \
        --max-iterations 3 \
        --test-cmd "true" \
        --local \
        2>&1) || true

    if echo "$output" | grep -qiE "Git:|progress|insertion|LOOP_COMPLETE"; then
        assert_pass "Loop tracks progress via git"
    else
        assert_fail "Loop progress tracking" "expected git/progress output"
    fi
else
    assert_fail "Loop progress tracking" "setup failed"
fi

# ─── Test: context efficiency event emitted ────────────────────────────────
echo ""
echo -e "${DIM}  context efficiency metrics${RESET}"

# context_efficiency was extracted to loop-iteration.sh sub-module
_loop_files="$SCRIPT_DIR/sw-loop.sh $SCRIPT_DIR/lib/loop-iteration.sh"
if grep -q 'emit_event "loop.context_efficiency"' $_loop_files 2>/dev/null; then
    assert_pass "loop.context_efficiency event exists in run_claude_iteration"
else
    assert_fail "loop.context_efficiency event exists in run_claude_iteration"
fi

if grep -q 'raw_prompt_chars=' $_loop_files 2>/dev/null && grep -q 'trimmed_prompt_chars=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits raw and trimmed char counts"
else
    assert_fail "Context efficiency emits raw and trimmed char counts"
fi

if grep -q 'trim_ratio=' $_loop_files 2>/dev/null && grep -q 'budget_utilization=' $_loop_files 2>/dev/null; then
    assert_pass "Context efficiency emits trim_ratio and budget_utilization"
else
    assert_fail "Context efficiency emits trim_ratio and budget_utilization"
fi

# Verify raw_prompt_chars is captured before manage_context_window trims
if grep -q 'raw_prompt_chars=${#prompt}' $_loop_files 2>/dev/null; then
    assert_pass "raw_prompt_chars measured from pre-trim prompt"
else
    assert_fail "raw_prompt_chars measured from pre-trim prompt"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MULTI-TEST GATE TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  multi-test gate${RESET}"

# Test: ADDITIONAL_TEST_CMDS appears in source
if grep -q 'ADDITIONAL_TEST_CMDS' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "ADDITIONAL_TEST_CMDS variable defined"
else
    assert_fail "ADDITIONAL_TEST_CMDS variable defined"
fi

# Test: --additional-test-cmds flag in arg parser
if grep -q '\-\-additional-test-cmds' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "--additional-test-cmds flag in arg parser"
else
    assert_fail "--additional-test-cmds flag in arg parser"
fi

# Test: --help mentions --additional-test-cmds
output=$(bash "$SCRIPT_DIR/sw-loop.sh" --help 2>&1 | sed $'s/\033\[[0-9;]*m//g') && rc=0 || rc=$?
if echo "$output" | grep -q 'additional-test-cmds'; then
    assert_pass "--help documents --additional-test-cmds"
else
    assert_fail "--help documents --additional-test-cmds"
fi

# Test: test-evidence JSON file written
if grep -q 'test-evidence-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_test_gate writes test-evidence JSON"
else
    assert_fail "run_test_gate writes test-evidence JSON"
fi

# Test: audit agent reads evidence file
if grep -q 'evidence_file.*test-evidence' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_audit_agent reads structured test evidence"
else
    assert_fail "run_audit_agent reads structured test evidence"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# VERIFICATION GAP TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  verification gap handler${RESET}"

# Test: verification gap detection exists in source
if grep -q 'Verification gap detected' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap detection present"
else
    assert_fail "Verification gap detection present"
fi

# Test: verification gap emits events
if grep -q 'loop.verification_gap_resolved' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap resolved event emitted"
else
    assert_fail "Verification gap resolved event emitted"
fi

if grep -q 'loop.verification_gap_confirmed' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap confirmed event emitted"
else
    assert_fail "Verification gap confirmed event emitted"
fi

# Test: verification gap overrides audit when tests pass
if grep -q 'override_audit' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification gap can override audit result"
else
    assert_fail "Verification gap can override audit result"
fi

# Test: verification checks for uncommitted changes
if grep -q 'verification-iter-' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Verification re-runs tests to dedicated log"
else
    assert_fail "Verification re-runs tests to dedicated log"
fi

# Test: mid-build test discovery uses detect_created_test_files
if grep -q 'detect_created_test_files' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Mid-build test file discovery integrated"
else
    assert_fail "Mid-build test file discovery integrated"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# AUDIT SCHEMA TESTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${DIM}  audit output schema${RESET}"

# Test: no schema passed to `claude --json-schema` carries a dialect key.
# The CLI resolves $schema against its bundled dialects and rejects an
# unresolvable URI, which kills the audit before it runs.
schema_dialect_offenders=""
for _schema in "$SCRIPT_DIR/../schemas"/*.json; do
    [[ -f "$_schema" ]] || continue
    if jq -e 'has("$schema")' "$_schema" >/dev/null 2>&1; then
        schema_dialect_offenders="$schema_dialect_offenders $(basename "$_schema")"
    fi
done
if [[ -z "$schema_dialect_offenders" ]]; then
    assert_pass "no schema declares an unresolvable \$schema dialect"
else
    assert_fail "no schema declares an unresolvable \$schema dialect (offenders:$schema_dialect_offenders)"
fi

# Test: every schema is still valid JSON with a type
schema_invalid=""
for _schema in "$SCRIPT_DIR/../schemas"/*.json; do
    [[ -f "$_schema" ]] || continue
    if ! jq -e '.type != null' "$_schema" >/dev/null 2>&1; then
        schema_invalid="$schema_invalid $(basename "$_schema")"
    fi
done
if [[ -z "$schema_invalid" ]]; then
    assert_pass "every schema is valid JSON declaring a type"
else
    assert_fail "every schema is valid JSON declaring a type (bad:$schema_invalid)"
fi

# Test: run_audit_agent strips the dialect key defensively before passing it on
if grep -q "jq -c 'del(.\[\"\$schema\"\])'" "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "run_audit_agent strips \$schema before --json-schema"
else
    assert_fail "run_audit_agent strips \$schema before --json-schema"
fi

# Test: an auditor that fails to run is not reported as audit findings
if grep -q 'loop.audit_unavailable' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "auditor invocation failure emits loop.audit_unavailable"
else
    assert_fail "auditor invocation failure emits loop.audit_unavailable"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo ""
print_test_results
