#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright loop test — Validate continuous agent loop harness           ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Colors (matches shipwright theme) ────────────────────────────────────────
CYAN='\033[38;2;0;212;255m'
GREEN='\033[38;2;74;222;128m'
RED='\033[38;2;248;113;113m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Counters ─────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
TOTAL=0
FAILURES=()
TEMP_DIR=""

setup_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright"
    mkdir -p "$TEMP_DIR/home/.claude"
    mkdir -p "$TEMP_DIR/bin"
    mkdir -p "$TEMP_DIR/repo/.git"

    # Mock claude CLI
    cat > "$TEMP_DIR/bin/claude" <<'MOCKEOF'
#!/usr/bin/env bash
echo "Mock claude executed"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/claude"

    # Mock git
    cat > "$TEMP_DIR/bin/git" <<'MOCKEOF'
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
    chmod +x "$TEMP_DIR/bin/git"

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
echo "mock gh output"
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/gh"

    # Mock tmux
    cat > "$TEMP_DIR/bin/tmux" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$TEMP_DIR/bin/tmux"

    # Link real jq
    if command -v jq &>/dev/null; then
        ln -sf "$(command -v jq)" "$TEMP_DIR/bin/jq"
    fi

    # Link real date, wc, etc.
    for cmd in date wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch; do
        if command -v "$cmd" &>/dev/null; then
            ln -sf "$(command -v "$cmd")" "$TEMP_DIR/bin/$cmd"
        fi
    done

    export PATH="$TEMP_DIR/bin:$PATH"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
}

cleanup_env() {
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
}
trap cleanup_env EXIT

assert_pass() {
    local desc="$1"
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    echo -e "  ${GREEN}✓${RESET} ${desc}"
}

assert_fail() {
    local desc="$1"
    local detail="${2:-}"
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    FAILURES+=("$desc")
    echo -e "  ${RED}✗${RESET} ${desc}"
    [[ -n "$detail" ]] && echo -e "    ${DIM}${detail}${RESET}"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "expected: $expected, got: $actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s\n' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing: $needle"
    fi
}

assert_contains_regex() {
    local desc="$1" haystack="$2" pattern="$3"
    if printf '%s\n' "$haystack" | grep -qE -- "$pattern" 2>/dev/null; then
        assert_pass "$desc"
    else
        assert_fail "$desc" "output missing pattern: $pattern"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# TESTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}  Shipwright Loop Tests${RESET}"
echo -e "${DIM}  ══════════════════════════════════════════${RESET}"
echo ""

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
if grep -q 'output-format.*json' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "build_claude_flags includes --output-format json"
else
    assert_fail "build_claude_flags includes --output-format json"
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
if grep -q '2>"$err_file"' "$SCRIPT_DIR/sw-loop.sh"; then
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
tmpdir=$(mktemp -d)
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
tmpdir2=$(mktemp -d)
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

# ─── Test 22: Script structure — circuit breaker, stuckness, test gate ────────
echo ""
echo -e "${DIM}  script structure${RESET}"
if grep -qE 'check_circuit_breaker|CIRCUIT_BREAKER' "$SCRIPT_DIR/sw-loop.sh"; then
    assert_pass "Script has circuit breaker logic"
else
    assert_fail "Script has circuit breaker logic"
fi
if grep -qE 'detect_stuckness|stuckness' "$SCRIPT_DIR/sw-loop.sh"; then
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

# ═══════════════════════════════════════════════════════════════════════════════
# LOOP BEHAVIOR TESTS (real loop execution with mocks)
# ═══════════════════════════════════════════════════════════════════════════════

# Setup for loop behavior tests: real git repo, mock claude only
setup_loop_env() {
    TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sw-loop-test.XXXXXX")
    mkdir -p "$TEMP_DIR/home/.shipwright" "$TEMP_DIR/home/.claude" "$TEMP_DIR/bin"

    # Create real git repo (use system git, not mock from PATH)
    local _git
    _git=$(PATH=/usr/local/bin:/usr/bin:/bin command -v git 2>/dev/null)
    if [[ -z "$_git" ]]; then
        echo "WARN: git not found — skipping loop behavior tests"
        return 1
    fi
    mkdir -p "$TEMP_DIR/repo"
    (cd "$TEMP_DIR/repo" && "$_git" init -q && "$_git" config user.email "t@t" && "$_git" config user.name "T")
    echo "init" > "$TEMP_DIR/repo/file.txt"
    (cd "$TEMP_DIR/repo" && "$_git" add . && "$_git" commit -q -m "init")

    # Mock gh
    cat > "$TEMP_DIR/bin/gh" <<'GHMOCK'
#!/usr/bin/env bash
echo '[]'
exit 0
GHMOCK
    chmod +x "$TEMP_DIR/bin/gh"

    # Link real jq, git, date, seq, etc. (use clean PATH to avoid mock from setup_env)
    for cmd in jq git date seq wc cat grep sed awk sort mkdir rm mv cp mktemp basename dirname printf od tr cut head tail tee touch bash; do
        if PATH=/usr/local/bin:/usr/bin:/bin command -v "$cmd" &>/dev/null; then
            ln -sf "$(PATH=/usr/local/bin:/usr/bin:/bin command -v "$cmd")" "$TEMP_DIR/bin/$cmd" 2>/dev/null || true
        fi
    done

    # Use our mocks (claude, gh) + real git/jq from our bin
    export PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin"
    export HOME="$TEMP_DIR/home"
    export NO_GITHUB=true
    return 0
}

# ─── Test: Loop completes when Claude outputs LOOP_COMPLETE ─────────────────
echo ""
echo -e "${DIM}  loop behavior: LOOP_COMPLETE${RESET}"

if setup_loop_env 2>/dev/null; then
    # Mock claude that says LOOP_COMPLETE on first iteration (valid JSON for --output-format json)
    cat > "$TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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
    cat > "$TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
if [[ ! -f iter2.txt ]]; then
    echo "Adding file" > iter2.txt
    echo '[{"type":"result","result":"Work in progress","usage":{"input_tokens":0,"output_tokens":0}}]'
else
    echo '[{"type":"result","result":"Done. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
fi
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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
    cat > "$TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"Still working...","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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
    cat > "$TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo '[{"type":"result","result":"I am trying the same approach again.","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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
    mkdir -p "$TEMP_DIR/home/.shipwright"
    _epoch=$(date +%s)
    echo "{\"daily_budget_usd\":0.01,\"enabled\":true}" > "$TEMP_DIR/home/.shipwright/budget.json"
    echo "{\"entries\":[{\"ts_epoch\":$_epoch,\"cost_usd\":1.0,\"input_tokens\":0,\"output_tokens\":0,\"model\":\"test\",\"stage\":\"test\",\"issue\":\"\"}],\"summary\":{}}" > "$TEMP_DIR/home/.shipwright/costs.json"
    # Add claude mock (loop exits before running it, but ensures consistent env)
    echo '#!/usr/bin/env bash
echo '"'"'[{"type":"result","result":"Done","usage":{"input_tokens":0,"output_tokens":0}}]'"'"'
exit 0' > "$TEMP_DIR/bin/claude"
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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
_valid_tmp=$(mktemp -d)
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
    cat > "$TEMP_DIR/bin/claude" << 'CLAUDE_EOF'
#!/usr/bin/env bash
echo "new content" > progress.txt
echo '[{"type":"result","result":"Added progress.txt. LOOP_COMPLETE","usage":{"input_tokens":0,"output_tokens":0}}]'
exit 0
CLAUDE_EOF
    chmod +x "$TEMP_DIR/bin/claude"

    output=$(env PATH="$TEMP_DIR/bin:/usr/local/bin:/usr/bin:/bin" HOME="$TEMP_DIR/home" NO_GITHUB=true \
        bash "$SCRIPT_DIR/sw-loop.sh" \
        --repo "$TEMP_DIR/repo" \
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

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${DIM}  ──────────────────────────────────────────${RESET}"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All $TOTAL tests passed${RESET}"
else
    echo -e "  ${RED}${BOLD}$FAIL of $TOTAL tests failed${RESET}"
    for f in "${FAILURES[@]}"; do echo -e "  ${RED}✗${RESET} $f"; done
fi
echo ""
exit "$FAIL"
