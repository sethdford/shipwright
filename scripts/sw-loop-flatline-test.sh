#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  sw-loop-flatline-test.sh — Flatline vs context exhaustion classification ║
# ║                                                                           ║
# ║  Unit tests for lib/loop-flatline.sh against a temp git repo.             ║
# ║  No real build loop or Claude needed.                                     ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
trap 'echo "ERROR: $BASH_SOURCE:$LINENO exited with status $?" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0

TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        echo "  ✓ $msg"
    else
        FAIL=$((FAIL + 1))
        echo "  ✗ $msg (expected: '$expected', got: '$actual')"
    fi
}

# Keep config lookups hermetic
export DAEMON_CONFIG="$TEST_TMP/no-such-config.json"
unset SW_LOOP_FLATLINE_THRESHOLD 2>/dev/null || true

source "$SCRIPT_DIR/lib/compat.sh"
source "$SCRIPT_DIR/lib/loop-flatline.sh"

CONTEXT_EXHAUSTION_PATTERNS="context.length.exceeded|maximum context length|context_length_exceeded|prompt is too long"

# Fresh repo + log dir + reset module state
setup_repo() {
    PROJECT_ROOT="$TEST_TMP/repo-$1"
    LOG_DIR="$PROJECT_ROOT/.claude/loop-logs"
    mkdir -p "$LOG_DIR"
    git -C "$PROJECT_ROOT" init -q
    git -C "$PROJECT_ROOT" config user.email t@t
    git -C "$PROJECT_ROOT" config user.name t
    echo "a" > "$PROJECT_ROOT/a.txt"
    git -C "$PROJECT_ROOT" add a.txt
    git -C "$PROJECT_ROOT" commit -qm init
    FLATLINE_STREAK=0
    FLATLINE_TOTAL=0
    flatline_reset_session
    STATUS="running"
    TEST_PASSED="false"
    TEST_OUTPUT=""
    ITERATION=1
    MAX_ITERATIONS=20
    LOG_FILE="$LOG_DIR/iteration-1.log"
    echo "working" > "$LOG_FILE"
}

write_errors() {
    jq -n --arg l "$1" '{iteration:1, error_count:1, error_lines:[$l]}' > "$LOG_DIR/error-summary.json"
}

commit_change() {
    echo "$1" >> "$PROJECT_ROOT/a.txt"
    git -C "$PROJECT_ROOT" commit -qam "$1"
}

echo "Flatline classification"

# ─── Three no-change, same-failure iterations → flatline ──────────────────────
setup_repo flat
write_errors "FAIL test_login: expected 200 got 500 (12ms)"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "first iteration is never flat (no prior fingerprint)"
write_errors "FAIL test_login: expected 200 got 500 (47ms)"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "flat" "$LAST_ITERATION_CLASS" "no commit + same failure (timings normalized) is flat"
flatline_classify_iteration "$LOG_FILE" true 0
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "3" "$FLATLINE_STREAK" "streak counts consecutive flat iterations"
assert_eq "flatline" "$(loop_resolve_exit_class)" "streak at threshold resolves to flatline"

# made_progress=true is ignored when HEAD did not move (check_progress diffs HEAD~1)
assert_eq "flat" "$LAST_ITERATION_CLASS" "no-commit iteration is flat even if check_progress says true"

# ─── A productive iteration resets the streak, total survives ─────────────────
commit_change "fix"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "new commit is productive"
assert_eq "0" "$FLATLINE_STREAK" "productive iteration resets streak"
assert_eq "3" "$FLATLINE_TOTAL" "total kept after reset"
flatline_reset_session
assert_eq "3" "$FLATLINE_TOTAL" "total survives a session restart"

# ─── Dirty tree with same HEAD is not flat ───────────────────────────────────
setup_repo dirty
write_errors "FAIL x"
flatline_classify_iteration "$LOG_FILE" true 0
echo "wip" >> "$PROJECT_ROOT/a.txt"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "uncommitted source edits are not flat"

# ─── Different failure is not flat ───────────────────────────────────────────
setup_repo different
write_errors "FAIL test_a"
flatline_classify_iteration "$LOG_FILE" true 0
write_errors "FAIL test_b"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "a new failure is movement, not flat"

# ─── No fingerprint and exit 0 is never flat ─────────────────────────────────
setup_repo nofp
TEST_PASSED=""
flatline_classify_iteration "$LOG_FILE" false 0
flatline_classify_iteration "$LOG_FILE" false 0
flatline_classify_iteration "$LOG_FILE" false 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "empty fingerprints never match"
assert_eq "0" "$FLATLINE_STREAK" "no streak without a failure signal"

# ─── Same non-zero exit code counts as repeated failure ──────────────────────
setup_repo exitcode
flatline_classify_iteration "$LOG_FILE" false 1
flatline_classify_iteration "$LOG_FILE" false 1
assert_eq "flat" "$LAST_ITERATION_CLASS" "same non-zero exit code + no change is flat"

# ─── Commits touching only .claude/ bookkeeping are not code changes ─────────
setup_repo bookkeeping
write_errors "FAIL test_login"
flatline_classify_iteration "$LOG_FILE" true 0
echo "iter 2" > "$LOG_DIR/progress.md"
git -C "$PROJECT_ROOT" add -A && git -C "$PROJECT_ROOT" commit -qm "loop: iteration 2"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "flat" "$LAST_ITERATION_CLASS" ".claude/-only auto-commit + same failure is flat"
echo "real" >> "$PROJECT_ROOT/a.txt"
echo "iter 3" > "$LOG_DIR/progress.md"
git -C "$PROJECT_ROOT" add -A && git -C "$PROJECT_ROOT" commit -qm "loop: iteration 3"
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "productive" "$LAST_ITERATION_CLASS" "commit with a source change is productive"

# ─── A test that fails silently, repeatedly, with no change is flat ──────────
setup_repo silent
rm -f "$LOG_DIR/error-summary.json"
flatline_classify_iteration "$LOG_FILE" true 0
flatline_classify_iteration "$LOG_FILE" true 0
assert_eq "flat" "$LAST_ITERATION_CLASS" "silent test failure with no change is flat"

# ─── Passing tests are never flat ────────────────────────────────────────────
setup_repo passing
TEST_PASSED="true"
write_errors "FAIL x"
flatline_classify_iteration "$LOG_FILE" false 1
flatline_classify_iteration "$LOG_FILE" false 1
assert_eq "productive" "$LAST_ITERATION_CLASS" "passing tests with no diff are productive"

# ─── Context exhaustion wins and resets the streak ───────────────────────────
setup_repo ctx
write_errors "FAIL x"
flatline_classify_iteration "$LOG_FILE" false 1
flatline_classify_iteration "$LOG_FILE" false 1
assert_eq "1" "$FLATLINE_STREAK" "streak building before exhaustion"
echo "Error: prompt is too long" > "$LOG_DIR/iteration-1.stderr"
flatline_classify_iteration "$LOG_FILE" false 1
assert_eq "context_exhaustion" "$LAST_ITERATION_CLASS" "exhaustion pattern in stderr wins over flat signals"
assert_eq "0" "$FLATLINE_STREAK" "exhaustion resets streak"
assert_eq "context_exhaustion" "$(loop_resolve_exit_class)" "exit class follows last iteration class"

# ─── Exit class resolution ───────────────────────────────────────────────────
echo "Exit class resolution"
LAST_ITERATION_CLASS="productive"; FLATLINE_STREAK=0; TEST_PASSED="false"; ITERATION=5; MAX_ITERATIONS=20
STATUS="complete";                   assert_eq "complete" "$(loop_resolve_exit_class)" "complete"
STATUS="context_exhaustion_restart"; assert_eq "context_exhaustion" "$(loop_resolve_exit_class)" "context_exhaustion_* status"
STATUS="max_iterations";             assert_eq "iteration_exhaustion" "$(loop_resolve_exit_class)" "max_iterations → iteration_exhaustion"
STATUS="circuit_breaker";            assert_eq "circuit_breaker" "$(loop_resolve_exit_class)" "circuit_breaker passes through"
FLATLINE_STREAK=2;                   assert_eq "flatline" "$(loop_resolve_exit_class)" "circuit_breaker with streak 2 → flatline"
STATUS="stuck_restart";              assert_eq "flatline" "$(loop_resolve_exit_class)" "stuck_restart with streak 2 → flatline"
STATUS="running"; FLATLINE_STREAK=2; assert_eq "running" "$(loop_resolve_exit_class)" "running below threshold passes through"
FLATLINE_STREAK=0; ITERATION=20;     assert_eq "iteration_exhaustion" "$(loop_resolve_exit_class)" "iteration at max without passing tests"
STATUS="complete"; FLATLINE_STREAK=9; assert_eq "complete" "$(loop_resolve_exit_class)" "complete beats flatline"

# ─── Artifact ────────────────────────────────────────────────────────────────
echo "Artifact"
LOOP_EXIT_CLASS="flatline"
flatline_write_artifact
assert_eq "0" "$(jq -e . "$LOG_DIR/flatline.json" >/dev/null 2>&1; echo $?)" "flatline.json is valid JSON"
assert_eq "flatline" "$(jq -r .exit_class "$LOG_DIR/flatline.json")" "artifact carries exit class"
assert_eq "0" "$(find "$LOG_DIR" -name '*.tmp.*' | wc -l | tr -d ' ')" "no tmp files left behind"

# ─── Fail-open robustness ────────────────────────────────────────────────────
echo "Fail-open"
PROJECT_ROOT="$TEST_TMP/not-a-repo"; mkdir -p "$PROJECT_ROOT"
LOG_DIR="$TEST_TMP/missing-logs"
flatline_reset_session; TEST_PASSED="false"
rc=0; flatline_classify_iteration "$LOG_DIR/iteration-1.log" true 0 || rc=$?
assert_eq "0" "$rc" "classifier returns 0 outside a git repo"
assert_eq "productive" "$LAST_ITERATION_CLASS" "outside a git repo defaults to productive"
rc=0; flatline_write_artifact || rc=$?
assert_eq "0" "$rc" "artifact writer returns 0 when LOG_DIR is missing"

# ─── Threshold config ────────────────────────────────────────────────────────
echo "Threshold config"
assert_eq "3" "$(_flatline_threshold)" "default threshold is 3"
assert_eq "5" "$(SW_LOOP_FLATLINE_THRESHOLD=5 _flatline_threshold)" "SW_ env override honored"
assert_eq "3" "$(SW_LOOP_FLATLINE_THRESHOLD=0 _flatline_threshold)" "zero falls back to 3"
assert_eq "3" "$(SW_LOOP_FLATLINE_THRESHOLD=abc _flatline_threshold)" "garbage falls back to 3"
echo '{"loop":{"flatline_threshold":4}}' > "$TEST_TMP/cfg.json"
assert_eq "4" "$(DAEMON_CONFIG="$TEST_TMP/cfg.json" _flatline_threshold)" "daemon-config value honored"

# ─── progress.md surfaces the exit class ─────────────────────────────────────
echo "progress.md"
source "$SCRIPT_DIR/lib/loop-progress.sh"
PROJECT_ROOT="$TEST_TMP/not-a-repo"
LOG_DIR="$TEST_TMP/progress-logs"; mkdir -p "$LOG_DIR"
GOAL="g"; ITERATION=6; MAX_ITERATIONS=20; TEST_PASSED="false"; STATUS="circuit_breaker"
LOOP_EXIT_CLASS=""; FLATLINE_STREAK=3; FLATLINE_THRESHOLD=3; LAST_ITERATION_CLASS="flatline"
write_progress
assert_eq "1" "$(grep -c '^- Exit class: flatline$' "$LOG_DIR/progress.md" || true)" "progress.md records Exit class: flatline"
assert_eq "1" "$(grep -c '^- Flatline streak: 3/3$' "$LOG_DIR/progress.md" || true)" "progress.md records flatline streak"
assert_eq "1" "$(grep -c '^- Tests passing: false$' "$LOG_DIR/progress.md" || true)" "existing Tests passing line unchanged"
FLATLINE_STREAK=0; LAST_ITERATION_CLASS="context_exhaustion"; STATUS="context_exhaustion_fatal"
write_progress
assert_eq "1" "$(grep -c '^- Exit class: context_exhaustion$' "$LOG_DIR/progress.md" || true)" "progress.md records Exit class: context_exhaustion"

# ─── loop_read_exit_class: the shared progress.md parser ─────────────────────
echo "loop_read_exit_class"
assert_eq "" "$(loop_read_exit_class "$TEST_TMP/no-such-progress.md")" "missing file reads as empty"
assert_eq "" "$(loop_read_exit_class "")" "no argument reads as empty"
printf -- '- Iteration: 3/20\n- Tests passing: false\n' > "$TEST_TMP/legacy-progress.md"
assert_eq "" "$(loop_read_exit_class "$TEST_TMP/legacy-progress.md")" "legacy progress.md without the line reads as empty"
printf -- '- Exit class: context_exhaustion\n- Exit class: iteration_exhaustion\n' > "$TEST_TMP/multi-progress.md"
assert_eq "iteration_exhaustion" "$(loop_read_exit_class "$TEST_TMP/multi-progress.md")" "last Exit class line wins"
assert_eq "context_exhaustion" "$(loop_read_exit_class "$LOG_DIR/progress.md")" "reads what write_progress wrote"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
