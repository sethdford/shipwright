#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  shipwright lib/test-gate-baseline test — differential test gate (#8633)  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/test-helpers.sh"

print_test_header "Lib: test-gate-baseline Tests"

setup_test_env "sw-lib-test-gate-baseline-test"
trap cleanup_test_env EXIT

# A fake suite runner in sw-test-all.sh's output format. suite-a/b/c; the suites named in
# fail.txt fail. Each run appends to $RUNS_FILE so the tests can count baseline runs.
REPO="$TEST_TEMP_DIR/project"
RUNS_FILE="$TEST_TEMP_DIR/runs.txt"
export LOG_DIR="$TEST_TEMP_DIR/logs"
mkdir -p "$REPO" "$LOG_DIR"
cat > "$REPO/runner.sh" <<'RUNNER'
#!/usr/bin/env bash
# Fake runner: prints sw-test-all.sh-style lines; exits 1 when any suite in fail.txt fails.
cd "$(dirname "$0")"
fails="$(cat fail.txt 2>/dev/null || true)"
failed=0; passed=0
for s in suite-a suite-b suite-c; do
    if printf '%s\n' "$fails" | grep -Fx -- "$s" >/dev/null; then
        printf '  ✗ %-46s exit 1 0s\n' "$s"
        failed=$((failed + 1))
    else
        printf '  ✓ %-46s 0s\n' "$s"
        passed=$((passed + 1))
    fi
done
printf '\n  %s passed  %s failed  0 timed out  (3 suites, 0s)\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
RUNNER
mkdir -p "$REPO/node_modules" && echo sentinel > "$REPO/node_modules/sentinel.txt"
# The runner records each execution here; the test command is `bash runner.sh`.
cat > "$REPO/counting-runner.sh" <<COUNTING
#!/usr/bin/env bash
echo run >> "$RUNS_FILE"
bash "\$(dirname "\$0")/runner.sh"
COUNTING

git_in_repo() { git -C "$REPO" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false "$@"; }
git_in_repo init -q
git_in_repo config core.hooksPath /dev/null
# commit_fail <list> — set fail.txt to the space-separated suites and commit; prints the new SHA.
commit_fail() {
    printf '%s' "$1" | tr ' ' '\n' > "$REPO/fail.txt"
    git_in_repo add -A >/dev/null 2>&1
    git_in_repo commit -q --allow-empty -m "state: fail=[$1]" >/dev/null 2>&1
    git_in_repo rev-parse HEAD
}
# iter_log <log> — run the suite runner in the repo's current state; log its output.
iter_log() {
    local log="$1" rc=0
    ( cd "$REPO" && bash runner.sh ) > "$log" 2>&1 || rc=$?
    echo "$rc"
}

# Sourced after the repo exists: the lib reads PROJECT_ROOT and LOG_DIR at call time.
export PROJECT_ROOT="$REPO"
export SW_TEST_TIMEOUT=120
source "$SCRIPT_DIR/lib/test-gate-env.sh"
_SW_TEST_GATE_BASELINE_LOADED=""
source "$SCRIPT_DIR/lib/test-gate-baseline.sh"

# Scenario helper: base commit with fail=$1, iteration commit with fail=$2 (command is runner.sh).
# Sets BASE_SHA and ITER_LOG, and the iteration exit code in ITER_RC.
scenario() {
    local base_fail="$1" iter_fail="$2"
    BASE_SHA="$(commit_fail "$base_fail")"
    commit_fail "$iter_fail" >/dev/null
    ITER_LOG="$LOG_DIR/iter-$(printf '%s' "$BASE_SHA" | cut -c1-8)-$RANDOM.log"
    ITER_RC="$(iter_log "$ITER_LOG")"
    LOOP_START_COMMIT="$BASE_SHA"
    tg_begin_gate
}

CMD="bash runner.sh"
COUNT_CMD="bash counting-runner.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# tg_parse_log
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_parse_log"

scenario "suite-b" "suite-b suite-c"
tg_parse_log "$ITER_LOG"
assert_eq "sw-test-all log: parsable" "1" "$TG_PARSABLE"
assert_eq "sw-test-all log: failing units" "suite-b
suite-c" "$TG_UNITS"

printf 'Ran 2 tests across 1 file. [11.00ms]\n(fail) bad two [3.09ms]\n' > "$TEST_TEMP_DIR/bun.log"
tg_parse_log "$TEST_TEMP_DIR/bun.log"
assert_eq "bun log: parsable" "1" "$TG_PARSABLE"
assert_eq "bun log: failing unit without timing" "bad two" "$TG_UNITS"

printf 'Error: Cannot find module\n' > "$TEST_TEMP_DIR/junk.log"
tg_parse_log "$TEST_TEMP_DIR/junk.log"
assert_eq "unknown output: not parsable" "0" "$TG_PARSABLE"

# ═══════════════════════════════════════════════════════════════════════════════
# Regression: the base commit passes, the iteration fails -> block
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "regression (base passes)"

scenario "" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "regression blocks" "1" "$rc"
assert_eq "regression: base exit recorded as 0" "0" "$TG_BASE_EXIT"
assert_eq "regression: verdict says NEW FAILURE" "1" "$(tg_verdict_text | grep -c 'NEW FAILURE' || true)"
assert_eq "regression: not marked pre-existing" "false" "$TG_PREEXISTING"

# ═══════════════════════════════════════════════════════════════════════════════
# Pre-existing: base and iteration fail the same suite -> do not block
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "pre-existing (same failures on base)"

scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "pre-existing does not block" "0" "$rc"
assert_eq "pre-existing recorded" "true" "$TG_PREEXISTING"
assert_eq "pre-existing: no new failures" "" "$TG_NEW_FAILURES"
if tg_verdict_text | grep 'Do NOT try to fix' >/dev/null; then
    assert_pass "pre-existing verdict tells the agent not to fix"
else
    assert_fail "pre-existing verdict tells the agent not to fix"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# New failure among pre-existing ones -> block, and list only the new suite
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "new failure among pre-existing failures"

scenario "suite-b" "suite-b suite-c"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "new failure blocks" "1" "$rc"
assert_eq "new_failures lists only the new suite" "suite-c" "$TG_NEW_FAILURES"
assert_eq "new failure is not marked pre-existing" "false" "$TG_PREEXISTING"

# ═══════════════════════════════════════════════════════════════════════════════
# Unparsable output that fails on base too -> pre-existing, not blocking
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "unparsable pre-existing failure"

UNPARSABLE_LOG="$LOG_DIR/unparsable.log"
printf 'boom\n' > "$UNPARSABLE_LOG"
git_in_repo commit -q --allow-empty -m "base for unparsable" >/dev/null 2>&1
UBASE="$(git_in_repo rev-parse HEAD)"
git_in_repo commit -q --allow-empty -m "iteration" >/dev/null 2>&1
LOOP_START_COMMIT="$UBASE"
printf '#!/usr/bin/env bash\necho boom\nexit 3\n' > "$REPO/broken.sh"
rc=0; tg_judge "bash broken.sh" "3" "$UNPARSABLE_LOG" 120 1 || rc=$?
assert_eq "unparsable pre-existing does not block" "0" "$rc"
assert_eq "unparsable pre-existing recorded" "true" "$TG_PREEXISTING"
rm -f "$REPO/broken.sh"

# ═══════════════════════════════════════════════════════════════════════════════
# Baseline cannot be computed -> block (fail closed)
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "baseline uncomputable"

scenario "suite-b" "suite-b"
LOOP_START_COMMIT=""
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "no LOOP_START_COMMIT blocks" "1" "$rc"
assert_eq "no LOOP_START_COMMIT: baseline uncomputable" "uncomputable" "$TG_BASE_EXIT"

scenario "suite-b" "suite-b"
LOOP_START_COMMIT="0000000000000000000000000000000000000000"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || rc=$?
assert_eq "unknown base commit blocks" "1" "$rc"
assert_eq "unknown base commit: baseline uncomputable" "uncomputable" "$TG_BASE_EXIT"

# A test created during this loop has no base-commit counterpart -> always block
scenario "suite-b" "suite-b"
rc=0; tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 0 || rc=$?
assert_eq "command created during the loop blocks" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
# Caching: the baseline runs once per command and base commit
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "baseline caching"

: > "$RUNS_FILE"
scenario "suite-b" "suite-b suite-c"
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
tg_judge "$COUNT_CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
assert_eq "baseline command ran once for three judgements" "1" "$(wc -l < "$RUNS_FILE" | tr -d ' ')"

# ═══════════════════════════════════════════════════════════════════════════════
# Worktree cleanup: the temporary worktree is removed; dependencies survive
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "worktree cleanup"

scenario "suite-b" "suite-b"
tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
worktrees="$(git_in_repo worktree list | wc -l | tr -d ' ')"
assert_eq "only the main worktree remains" "1" "$worktrees"
assert_file_exists "node_modules symlink target survives worktree removal" "$REPO/node_modules/sentinel.txt"

# ═══════════════════════════════════════════════════════════════════════════════
# tg_record: evidence JSON
# ═══════════════════════════════════════════════════════════════════════════════
print_test_section "tg_record evidence"

if command -v jq >/dev/null 2>&1; then
    scenario "suite-b" "suite-b suite-c"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: baseline_exit_code recorded (base fails: 1)" "1" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: new_failures listed" "suite-c" "$(echo "$results" | jq -r '.[0].new_failures | join(",")')"
    assert_eq "evidence: preexisting false" "false" "$(echo "$results" | jq -r '.[0].preexisting')"
    assert_eq "evidence: exit_code kept" "$ITER_RC" "$(echo "$results" | jq -r '.[0].exit_code')"

    scenario "suite-b" "suite-b"
    tg_judge "$CMD" "$ITER_RC" "$ITER_LOG" 120 1 || true
    results="$(tg_record "[]" "$CMD" "$ITER_RC" 7)"
    assert_eq "evidence: pre-existing recorded" "true" "$(echo "$results" | jq -r '.[0].preexisting')"

    results="$(tg_record "[]" "npm test" 0 3)"
    assert_eq "evidence: passing command has null baseline" "null" "$(echo "$results" | jq -r '.[0].baseline_exit_code')"
    assert_eq "evidence: passing command has no new failures" "0" "$(echo "$results" | jq -r '.[0].new_failures | length')"
else
    assert_pass "jq not installed: evidence checks skipped"
fi

print_test_results
